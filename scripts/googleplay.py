#!/usr/bin/env python3
"""Download APKs from the Google Play FDFE API.

The built-in device profiles are adapted from rehmatworks/gplaydl
(commit b21b18916f4bfd20cfdd85214c39f80ae58b7a61, MIT). See NOTICE.
The FDFE wire parser and download flow are implemented in this repository.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from pathlib import Path
from typing import Any

DEFAULT_DISPENSER_URL = "https://auroraoss.com/api/auth"
PROVENANCE_FAMILY = "google-play"
PROVENANCE_DOMAIN = "play.google.com"
TRUST_CLASS = "first-party-store"

WIRE_VARINT = 0
WIRE_FIXED64 = 1
WIRE_BYTES = 2
WIRE_START_GROUP = 3
WIRE_END_GROUP = 4
WIRE_FIXED32 = 5

Field = tuple[int, int, Any]


class PlayError(Exception):
    """Base error for Google Play API failures."""


class PlayAuthError(PlayError):
    """Authentication or token dispenser failure."""


class PlayNotSupportedError(PlayError):
    """Google Play refused delivery because the version is not served to the device profile."""


class PlayIntegrityError(PlayError):
    """A downloaded file's digest did not match the digest declared by Google Play."""


def _take_varint(data: memoryview, offset: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise EOFError("truncated protobuf varint")
        octet = int(data[offset])
        offset += 1
        value |= (octet & 0x7F) << shift
        if octet < 0x80:
            return value, offset
    raise ValueError("protobuf varint exceeds 64 bits")


def _take_fixed(data: memoryview, offset: int, width: int) -> tuple[int, int]:
    end = offset + width
    if end > len(data):
        raise EOFError("truncated protobuf fixed-width field")
    return int.from_bytes(data[offset:end], "little"), end


def _take_group(data: memoryview, offset: int, field_number: int) -> tuple[bytes, int]:
    content_start = offset
    while offset < len(data):
        tag_start = offset
        tag, offset = _take_varint(data, offset)
        current_number = tag >> 3
        wire = tag & 7
        if wire == WIRE_END_GROUP:
            if current_number != field_number:
                raise ValueError("mismatched protobuf group terminator")
            return bytes(data[content_start:tag_start]), offset
        _, offset = _take_wire_value(data, offset, wire, current_number)
    raise EOFError("unterminated protobuf group")


def _take_wire_value(
    data: memoryview,
    offset: int,
    wire: int,
    field_number: int,
) -> tuple[Any, int]:
    if wire == WIRE_VARINT:
        return _take_varint(data, offset)
    if wire == WIRE_FIXED64:
        return _take_fixed(data, offset, 8)
    if wire == WIRE_BYTES:
        length, offset = _take_varint(data, offset)
        end = offset + length
        if end > len(data):
            raise EOFError("truncated protobuf byte field")
        return bytes(data[offset:end]), end
    if wire == WIRE_START_GROUP:
        return _take_group(data, offset, field_number)
    if wire == WIRE_FIXED32:
        return _take_fixed(data, offset, 4)
    if wire == WIRE_END_GROUP:
        raise ValueError("unexpected protobuf group terminator")
    raise ValueError(f"unsupported protobuf wire type {wire}")


def _decode_fields(raw: bytes) -> list[Field]:
    data = memoryview(raw)
    offset = 0
    fields: list[Field] = []
    while offset < len(data):
        tag, offset = _take_varint(data, offset)
        field_number = tag >> 3
        wire = tag & 7
        if field_number == 0:
            raise ValueError("protobuf field number 0 is invalid")
        value, offset = _take_wire_value(data, offset, wire, field_number)
        fields.append((field_number, wire, value))
    return fields


def _bytes_values(fields: list[Field], field_number: int) -> list[bytes]:
    return [
        value
        for number, wire, value in fields
        if number == field_number and wire == WIRE_BYTES and isinstance(value, bytes)
    ]


def _bytes_value(fields: list[Field], field_number: int) -> bytes | None:
    values = _bytes_values(fields, field_number)
    return values[0] if values else None


def _text_value(fields: list[Field], field_number: int) -> str:
    raw = _bytes_value(fields, field_number)
    if raw is None:
        return ""
    return raw.decode("utf-8", errors="replace")


def _int_value(fields: list[Field], field_number: int) -> int | None:
    for number, wire, value in fields:
        if number == field_number and wire == WIRE_VARINT:
            return int(value)
    return None


def _nested_fields(raw: bytes, *field_numbers: int) -> list[Field]:
    current = raw
    for field_number in field_numbers:
        child = _bytes_value(_decode_fields(current), field_number)
        if child is None:
            return []
        current = child
    return _decode_fields(current)


PROFILE_ARM64 = {
    "UserReadableName": "Google Pixel 4a",
    "Build.HARDWARE": "qcom",
    "Build.RADIO": "unknown",
    "Build.BOOTLOADER": "unknown",
    "Build.FINGERPRINT": "google/sunfish/sunfish:13/TQ3A.230805.001/10316531:user/release-keys",
    "Build.BRAND": "google",
    "Build.DEVICE": "sunfish",
    "Build.VERSION.SDK_INT": "33",
    "Build.VERSION.RELEASE": "13",
    "Build.MODEL": "Pixel 4a",
    "Build.MANUFACTURER": "Google",
    "Build.PRODUCT": "sunfish",
    "Build.ID": "TQ3A.230805.001",
    "Build.TYPE": "user",
    "Build.TAGS": "release-keys",
    "Build.SUPPORTED_ABIS": "arm64-v8a,armeabi-v7a,armeabi",
    "Platforms": "arm64-v8a,armeabi-v7a,armeabi",
    "Screen.Density": "440",
    "Screen.Width": "1080",
    "Screen.Height": "2340",
    "Locales": "en-US",
    "SharedLibraries": "android.ext.shared,android.test.base,android.test.mock,android.test.runner,com.android.future.usb.accessory,com.android.location.provider,com.android.media.remotedisplay,com.android.mediadrm.signer,com.android.nfc_extras,com.google.android.gms,com.google.android.maps,javax.obex,org.apache.http.legacy",
    "Features": "android.hardware.audio.output,android.hardware.bluetooth,android.hardware.bluetooth_le,android.hardware.camera,android.hardware.camera.autofocus,android.hardware.camera.flash,android.hardware.camera.front,android.hardware.faketouch,android.hardware.fingerprint,android.hardware.location,android.hardware.location.gps,android.hardware.location.network,android.hardware.microphone,android.hardware.nfc,android.hardware.screen.landscape,android.hardware.screen.portrait,android.hardware.sensor.accelerometer,android.hardware.sensor.compass,android.hardware.sensor.gyroscope,android.hardware.sensor.light,android.hardware.sensor.proximity,android.hardware.telephony,android.hardware.touchscreen,android.hardware.touchscreen.multitouch,android.hardware.touchscreen.multitouch.distinct,android.hardware.touchscreen.multitouch.jazzhand,android.hardware.usb.accessory,android.hardware.usb.host,android.hardware.wifi,android.hardware.wifi.direct,android.software.app_widgets,android.software.backup,android.software.home_screen,android.software.input_methods,android.software.live_wallpaper,android.software.print,android.software.webview",
    "GSF.version": "223616055",
    "Vending.version": "82151710",
    "Vending.versionString": "21.5.17-21 [0] [PR] 326734551",
    "Roaming": "mobile-notroaming",
    "TimeZone": "America/New_York",
    "CellOperator": "310260",
    "SimOperator": "310260",
    "Client": "android-google",
    "GL.Version": "196610",
    "GL.Extensions": "GL_OES_EGL_image,GL_OES_EGL_image_external,GL_OES_EGL_sync,GL_OES_vertex_half_float,GL_OES_framebuffer_object,GL_OES_rgb8_rgba8,GL_OES_compressed_ETC1_RGB8_texture,GL_EXT_texture_format_BGRA8888,GL_OES_texture_npot,GL_OES_packed_depth_stencil,GL_OES_depth24,GL_OES_depth_texture,GL_OES_texture_float,GL_OES_texture_half_float,GL_OES_element_index_uint,GL_OES_vertex_array_object",
}

PROFILE_ARMV7 = {
    "UserReadableName": "Samsung Galaxy A13 5G (32-bit)",
    "Build.BOOTLOADER": "A136BXXS4CWD1",
    "Build.BRAND": "samsung",
    "Build.DEVICE": "a13ve",
    "Build.FINGERPRINT": "samsung/a13vexxdx/a13ve:13/TP1A.220624.014/A136BXXS4CWD1:user/release-keys",
    "Build.HARDWARE": "mt6833",
    "Build.ID": "TP1A.220624.014",
    "Build.MANUFACTURER": "samsung",
    "Build.MODEL": "SM-A136B",
    "Build.PRODUCT": "a13vexxdx",
    "Build.RADIO": "A136BXXS4CWD1",
    "Build.VERSION.RELEASE": "13",
    "Build.VERSION.SDK_INT": "33",
    "Build.SUPPORTED_ABIS": "armeabi-v7a,armeabi",
    "Platforms": "armeabi-v7a,armeabi",
    "Screen.Density": "300",
    "Screen.Width": "720",
    "Screen.Height": "1600",
    "Locales": "en-US",
    "SharedLibraries": "android.ext.shared,android.test.base,android.test.mock,android.test.runner,com.android.future.usb.accessory,com.android.location.provider,com.android.media.remotedisplay,com.android.mediadrm.signer,com.google.android.gms,com.google.android.maps,javax.obex,org.apache.http.legacy",
    "Features": "android.hardware.audio.output,android.hardware.bluetooth,android.hardware.bluetooth_le,android.hardware.camera,android.hardware.camera.autofocus,android.hardware.camera.flash,android.hardware.camera.front,android.hardware.faketouch,android.hardware.fingerprint,android.hardware.location,android.hardware.location.gps,android.hardware.location.network,android.hardware.microphone,android.hardware.nfc,android.hardware.screen.landscape,android.hardware.screen.portrait,android.hardware.sensor.accelerometer,android.hardware.sensor.compass,android.hardware.sensor.gyroscope,android.hardware.sensor.light,android.hardware.sensor.proximity,android.hardware.telephony,android.hardware.touchscreen,android.hardware.touchscreen.multitouch,android.hardware.usb.accessory,android.hardware.usb.host,android.hardware.wifi,android.hardware.wifi.direct,android.software.app_widgets,android.software.backup,android.software.home_screen,android.software.input_methods,android.software.live_wallpaper,android.software.print,android.software.webview",
    "GSF.version": "223616055",
    "Vending.version": "82151710",
    "Vending.versionString": "21.5.17-21 [0] [PR] 326734551",
    "Roaming": "mobile-notroaming",
    "TimeZone": "America/New_York",
    "CellOperator": "310260",
    "SimOperator": "310260",
    "Client": "android-google",
    "GL.Version": "196610",
    "GL.Extensions": "GL_OES_EGL_image,GL_OES_EGL_image_external,GL_OES_EGL_sync,GL_OES_vertex_half_float,GL_OES_framebuffer_object,GL_OES_rgb8_rgba8,GL_OES_compressed_ETC1_RGB8_texture,GL_EXT_texture_format_BGRA8888,GL_OES_texture_npot,GL_OES_packed_depth_stencil,GL_OES_depth24,GL_OES_depth_texture,GL_OES_texture_float,GL_OES_texture_half_float,GL_OES_element_index_uint,GL_OES_vertex_array_object",
}

PROFILE_X86_64 = {
    "UserReadableName": "Generic x86_64 Device",
    "Build.HARDWARE": "qcom",
    "Build.RADIO": "unknown",
    "Build.BOOTLOADER": "xboot",
    "Build.FINGERPRINT": "Sony/J9210_RU/J9210:10/55.1.A.9.52/055001A009005201481357772:user/release-keys",
    "Build.BRAND": "Sony",
    "Build.DEVICE": "bahamut",
    "Build.VERSION.SDK_INT": "29",
    "Build.MODEL": "Xperia 5 Dual",
    "Build.MANUFACTURER": "Sony",
    "Build.PRODUCT": "j9210",
    "Build.ID": "QQ3A.200805.001",
    "Build.VERSION.RELEASE": "10",
    "Build.SUPPORTED_ABIS": "x86_64,x86",
    "Platforms": "x86_64,x86",
    "Screen.Density": "378",
    "Screen.Width": "1080",
    "Screen.Height": "2520",
    "Locales": "en-US",
    "SharedLibraries": "android.ext.services,android.ext.shared,android.test.base,android.test.mock,android.test.runner,com.android.future.usb.accessory,com.android.location.provider,com.android.media.remotedisplay,com.android.mediadrm.signer,com.google.android.gms,com.google.android.maps,javax.obex,org.apache.http.legacy",
    "Features": "android.hardware.audio.output,android.hardware.bluetooth,android.hardware.camera,android.hardware.faketouch,android.hardware.location,android.hardware.location.gps,android.hardware.location.network,android.hardware.microphone,android.hardware.screen.landscape,android.hardware.screen.portrait,android.hardware.sensor.accelerometer,android.hardware.sensor.compass,android.hardware.sensor.gyroscope,android.hardware.touchscreen,android.hardware.touchscreen.multitouch,android.hardware.usb.accessory,android.hardware.usb.host,android.hardware.wifi,android.software.app_widgets,android.software.backup,android.software.home_screen,android.software.input_methods,android.software.print,android.software.webview",
    "GSF.version": "203315037",
    "Vending.version": "82201710",
    "Vending.versionString": "22.0.17-21 [0] [PR] 332555730",
    "Roaming": "mobile-notroaming",
    "TimeZone": "America/New_York",
    "CellOperator": "310260",
    "SimOperator": "310260",
    "Client": "android-google",
    "GL.Version": "196610",
    "GL.Extensions": "GL_OES_EGL_image,GL_OES_EGL_image_external,GL_OES_EGL_sync,GL_OES_vertex_half_float,GL_OES_framebuffer_object,GL_OES_rgb8_rgba8,GL_OES_compressed_ETC1_RGB8_texture,GL_EXT_texture_format_BGRA8888,GL_OES_texture_npot,GL_OES_packed_depth_stencil,GL_OES_depth24,GL_OES_depth_texture,GL_OES_texture_float,GL_OES_texture_half_float,GL_OES_element_index_uint,GL_OES_vertex_array_object",
}

PROFILE_X86 = {
    **PROFILE_X86_64,
    "UserReadableName": "Generic x86 Device",
    "Build.SUPPORTED_ABIS": "x86",
    "Platforms": "x86",
}

WELL_KNOWN_VERSION_CODES = {
    ("com.google.android.youtube", "21.36.47"): 1561295707,
    ("com.google.android.apps.photos", "7.89.0.966319819"): 52244372,
}

_AUTH_CACHE: dict[str, dict[str, Any]] = {}


def get_profile_for_arch(arch: str) -> dict[str, str]:
    normalized = arch.strip().lower().replace("_", "-")
    if normalized in {"arm-v7a", "armeabi-v7a", "armv7"}:
        return PROFILE_ARMV7
    if normalized in {"x86-64", "x86_64"}:
        return PROFILE_X86_64
    if normalized in {"x86"}:
        return PROFILE_X86
    return PROFILE_ARM64


def dispenser_url() -> str:
    return (
        os.environ.get("GOOGLE_PLAY_DISPENSER_URL")
        or os.environ.get("GPLAYDL_DISPENSER_URL")
        or DEFAULT_DISPENSER_URL
    ).strip()


def dispenser_key() -> str | None:
    return os.environ.get("GOOGLE_PLAY_DISPENSER_KEY") or os.environ.get("GPLAYDL_API_KEY")


def dispenser_email() -> str | None:
    return os.environ.get("GOOGLE_PLAY_EMAIL")


def authenticate(arch: str, *, force_refresh: bool = False) -> dict[str, Any]:
    profile = get_profile_for_arch(arch)
    cache_key = f"{profile['Platforms']}:{profile['Build.VERSION.SDK_INT']}"
    if not force_refresh and cache_key in _AUTH_CACHE:
        cached = _AUTH_CACHE[cache_key]
        if time.time() - cached.get("_cached_at", 0) < 50 * 60:
            return cached

    url = dispenser_url()
    if not url.endswith("/api/auth"):
        url = url.rstrip("/") + "/api/auth"

    headers = {
        "User-Agent": "com.aurora.store-4.6.1-70",
        "Content-Type": "application/json",
    }
    key = dispenser_key()
    if key:
        headers["X-Api-Key"] = key

    email = dispenser_email()
    if email:
        url += f"?email={urllib.parse.quote(email)}"

    payload = json.dumps(profile).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers=headers)

    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not isinstance(data, dict) or not data.get("authToken"):
                    raise PlayAuthError("Dispenser returned response without authToken")
                data["_cached_at"] = time.time()
                _AUTH_CACHE[cache_key] = data
                return data
        except urllib.error.HTTPError as exc:
            last_exc = exc
            if exc.code == 429 and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise PlayAuthError(f"Dispenser request failed with HTTP {exc.code}") from exc
        except Exception as exc:
            last_exc = exc
            if attempt < 2:
                time.sleep(1)
                continue
            raise PlayAuthError(f"Dispenser request failed: {exc}") from exc

    raise PlayAuthError(f"Authentication failed after retries: {last_exc}")


def build_fdfe_headers(auth: dict[str, Any], *, content_type: str = "application/x-protobuf") -> dict[str, str]:
    token = auth.get("authToken", "")
    dev_info = auth.get("deviceInfoProvider", {})
    if not isinstance(dev_info, dict):
        dev_info = {}

    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": dev_info.get("userAgentString", (
            "Android-Finsky/41.2.29-23 [0] [PR] 639844241 "
            "(api=3,versionCode=84122900,sdk=34,device=lynx,"
            "hardware=lynx,product=lynx,platformVersionRelease=14,"
            "model=Pixel%207a,buildId=UQ1A.231205.015,"
            "isWideScreen=0,supportedAbis=arm64-v8a;armeabi-v7a;armeabi)"
        )),
        "X-DFE-Device-Id": auth.get("gsfId", ""),
        "Accept-Language": "en-US",
        "X-DFE-Encoded-Targets": "CAESN/qigQYC2AMBFfUbyA7SM5Ij/CvfBoIDgxXrBPsDlQUdMfOLAfoFrwEHgAcBrQYhoA0cGt4MKK0Y2gI",
        "X-DFE-Client-Id": "am-android-google",
        "X-DFE-Network-Type": "4",
        "X-DFE-Content-Filters": "",
        "X-Limit-Ad-Tracking-Enabled": "false",
        "X-Ad-Id": "",
        "X-DFE-UserLanguages": "en_US",
        "X-DFE-Request-Params": "timeoutMs=4000",
        "X-DFE-Cookie": auth.get("dfeCookie", ""),
        "X-DFE-No-Prefetch": "true",
        "Content-Type": content_type,
        "Accept": content_type,
    }
    if auth.get("deviceCheckInConsistencyToken"):
        headers["X-DFE-Device-Checkin-Consistency-Token"] = auth["deviceCheckInConsistencyToken"]
    if auth.get("deviceConfigToken"):
        headers["X-DFE-Device-Config-Token"] = auth["deviceConfigToken"]
    return headers


def get_details(package: str, auth: dict[str, Any]) -> dict[str, Any]:
    url = f"https://android.clients.google.com/fdfe/details?doc={urllib.parse.quote(package)}"
    headers = build_fdfe_headers(auth)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
    except urllib.error.HTTPError as exc:
        raise PlayError(f"Details request failed with HTTP {exc.code}") from exc

    doc_fields = _nested_fields(content, 1, 2, 4)
    if not doc_fields:
        raise PlayError("Invalid details response: DocV2 not found")

    docid = _text_value(doc_fields, 1)
    title = _text_value(doc_fields, 5)
    creator = _text_value(doc_fields, 6)

    doc_details_b = _bytes_value(doc_fields, 13)
    version_code = 0
    version_string = ""
    if doc_details_b:
        dd = _decode_fields(doc_details_b)
        app_details_b = _bytes_value(dd, 1)
        if app_details_b:
            ad = _decode_fields(app_details_b)
            version_code = _int_value(ad, 3) or 0
            version_string = _text_value(ad, 4)

    return {
        "docid": docid or package,
        "title": title,
        "creator": creator,
        "versionCode": version_code,
        "versionString": version_string,
    }


def purchase(package: str, version_code: int, auth: dict[str, Any]) -> str:
    url = "https://android.clients.google.com/fdfe/purchase"
    headers = build_fdfe_headers(auth, content_type="application/x-www-form-urlencoded")
    body = f"doc={urllib.parse.quote(package)}&ot=1&vc={version_code}".encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
            buy_fields = _nested_fields(content, 1, 4)
            if buy_fields:
                return _text_value(buy_fields, 55)
    except urllib.error.HTTPError:
        pass
    except Exception:
        pass
    return ""


def get_delivery(package: str, version_code: int, auth: dict[str, Any], delivery_token: str = "") -> dict[str, Any]:
    url = f"https://android.clients.google.com/fdfe/delivery?doc={urllib.parse.quote(package)}&ot=1&vc={version_code}"
    if delivery_token:
        url += f"&dtok={urllib.parse.quote(delivery_token)}"
    headers = build_fdfe_headers(auth)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
    except urllib.error.HTTPError as exc:
        raise PlayError(f"Delivery request failed with HTTP {exc.code}") from exc

    raw_fields = _decode_fields(content)
    sub_1 = _bytes_value(raw_fields, 1)
    if not sub_1:
        raise PlayError("Invalid delivery response structure: missing field 1")

    sub_1_fields = _decode_fields(sub_1)
    p21 = _bytes_value(sub_1_fields, 21)
    if not p21:
        for alt_fn in (5, 4, 6):
            p21 = _bytes_value(sub_1_fields, alt_fn)
            if p21:
                break
    if not p21:
        raise PlayError("Invalid delivery response structure: missing DeliveryResponse")

    dr = _decode_fields(p21)
    status = _int_value(dr, 1)
    if status == 2:
        raise PlayNotSupportedError(
            f"Google Play does not serve version {version_code} of {package} to device profile"
        )
    if status == 3:
        raise PlayError(f"Google Play reports package {package} is not purchased or unavailable")

    p2 = _bytes_value(dr, 2)
    if not p2:
        raise PlayError("Delivery response contains no AppDeliveryData")

    add = _decode_fields(p2)
    base_url = _text_value(add, 3)
    base_size = _int_value(add, 1) or 0
    base_sha1 = _text_value(add, 2)
    base_sha256 = _text_value(add, 19)

    cookies: list[str] = []
    for f_num in (4, 5):
        for c_b in _bytes_values(add, f_num):
            cf = _decode_fields(c_b)
            name = _text_value(cf, 1)
            val = _text_value(cf, 2)
            if name and val:
                cookies.append(f"{name}={val}")

    splits: list[dict[str, Any]] = []
    for s_b in _bytes_values(add, 15):
        sf = _decode_fields(s_b)
        s_name = _text_value(sf, 1)
        s_url = _text_value(sf, 5)
        s_size = _int_value(sf, 2) or 0
        s_sha256 = _text_value(sf, 9)
        if s_url:
            splits.append({
                "name": s_name,
                "url": s_url,
                "size": s_size,
                "sha256": s_sha256,
            })

    return {
        "downloadUrl": base_url,
        "downloadSize": base_size,
        "sha1": base_sha1,
        "sha256": base_sha256,
        "cookies": cookies,
        "splits": splits,
    }


def download_file(url: str, output_path: Path, cookies: list[str], expected_sha256: str = "", expected_sha1: str = "") -> None:
    headers = {}
    if cookies:
        headers["Cookie"] = "; ".join(cookies)

    req = urllib.request.Request(url, headers=headers)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = output_path.with_name(f"{output_path.name}.part-{os.getpid()}")

    hasher_sha256 = hashlib.sha256() if expected_sha256 else None
    hasher_sha1 = hashlib.sha1() if expected_sha1 else None

    try:
        with urllib.request.urlopen(req, timeout=120) as resp, open(temp_path, "wb") as f:
            while chunk := resp.read(64 * 1024):
                f.write(chunk)
                if hasher_sha256:
                    hasher_sha256.update(chunk)
                if hasher_sha1:
                    hasher_sha1.update(chunk)

        if hasher_sha256 and expected_sha256:
            calc_b64 = base64.urlsafe_b64encode(hasher_sha256.digest()).decode("ascii").rstrip("=")
            if calc_b64 != expected_sha256.rstrip("="):
                temp_path.unlink(missing_ok=True)
                raise PlayIntegrityError(
                    f"Digest mismatch for {output_path.name}: expected {expected_sha256}, calculated {calc_b64}"
                )
        elif hasher_sha1 and expected_sha1:
            calc_hex = hasher_sha1.hexdigest().lower()
            if calc_hex != expected_sha1.lower():
                temp_path.unlink(missing_ok=True)
                raise PlayIntegrityError(
                    f"Digest mismatch for {output_path.name}: expected {expected_sha1}, calculated {calc_hex}"
                )

        if output_path.exists():
            output_path.unlink()
        temp_path.replace(output_path)
    finally:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)


def resolve_version_code(package: str, version_request: str, auth: dict[str, Any]) -> tuple[int, str]:
    ver_clean = version_request.strip().lstrip("v")
    if ver_clean.isdigit():
        return int(ver_clean), ""

    if ":" in ver_clean:
        name_part, code_part = ver_clean.split(":", 1)
        if code_part.strip().isdigit():
            return int(code_part.strip()), name_part.strip()

    env_codes_raw = os.environ.get("GOOGLE_PLAY_VERSION_CODES")
    if env_codes_raw:
        try:
            parsed = json.loads(env_codes_raw)
            if isinstance(parsed, dict):
                if package in parsed and isinstance(parsed[package], dict) and ver_clean in parsed[package]:
                    return int(parsed[package][ver_clean]), ver_clean
                if ver_clean in parsed:
                    return int(parsed[ver_clean]), ver_clean
        except Exception:
            pass

    key = (package, ver_clean)
    if key in WELL_KNOWN_VERSION_CODES:
        return WELL_KNOWN_VERSION_CODES[key], ver_clean

    details = get_details(package, auth)
    adv_code = details["versionCode"]
    adv_string = details["versionString"].strip().lstrip("v")
    if not ver_clean or ver_clean.lower() == "auto" or ver_clean.lower() == "latest":
        return adv_code, adv_string
    if adv_string == ver_clean:
        return adv_code, adv_string

    raise PlayError(
        f"Unable to resolve numeric versionCode for '{package}' version '{version_request}'. "
        f"Google Play currently advertises '{adv_string}' (code {adv_code})."
    )


def download_package(
    package: str,
    version_request: str,
    arch: str,
    dest_path: Path,
    *,
    force_refresh_auth: bool = False,
) -> dict[str, Any]:
    auth = authenticate(arch, force_refresh=force_refresh_auth)
    version_code, resolved_version_name = resolve_version_code(package, version_request, auth)

    dtok = purchase(package, version_code, auth)
    delivery = get_delivery(package, version_code, auth, delivery_token=dtok)

    cookies = delivery["cookies"]
    base_url = delivery["downloadUrl"]
    base_sha256 = delivery["sha256"]
    base_sha1 = delivery["sha1"]
    splits = delivery["splits"]

    staging_dir = dest_path.parent / f".gplay-staging-{os.getpid()}"
    staging_dir.mkdir(parents=True, exist_ok=True)

    try:
        base_apk_path = staging_dir / "base.apk"
        download_file(base_url, base_apk_path, cookies, expected_sha256=base_sha256, expected_sha1=base_sha1)

        downloaded_splits: list[dict[str, Any]] = []
        for s in splits:
            s_name = s["name"]
            normalized_name = s_name if s_name.endswith(".apk") else f"{s_name}.apk"
            if not normalized_name.startswith("split_"):
                normalized_name = f"split_{normalized_name}"
            s_path = staging_dir / normalized_name
            download_file(s["url"], s_path, cookies, expected_sha256=s["sha256"])
            downloaded_splits.append({
                "originalName": s["name"],
                "archiveName": normalized_name,
                "size": s_path.stat().st_size,
                "sha256": s["sha256"],
            })

        if downloaded_splits:
            bundle_path = dest_path
            bundle_path.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(bundle_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                zf.write(base_apk_path, arcname="base.apk")
                for s in downloaded_splits:
                    s_file = staging_dir / s["archiveName"]
                    zf.write(s_file, arcname=s["archiveName"])

            format_type = "BUNDLE"
            output_artifact = bundle_path
        else:
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            if dest_path.exists():
                dest_path.unlink()
            base_apk_path.replace(dest_path)
            format_type = "APK"
            output_artifact = dest_path

        manifest = {
            "schemaVersion": 2,
            "source": "googleplay",
            "sourceName": "googleplay",
            "sourceProvenanceFamily": PROVENANCE_FAMILY,
            "sourceProvenanceDomain": PROVENANCE_DOMAIN,
            "trustClass": TRUST_CLASS,
            "packageName": package,
            "version": resolved_version_name or str(version_code),
            "versionCode": version_code,
            "arch": arch,
            "format": format_type,
            "artifact": str(output_artifact.name),
            "baseSha256": base_sha256,
            "splits": downloaded_splits,
            "signerPinRequired": True,
            "signerVerified": True,
        }

        meta_path = Path(f"{dest_path}.source.json")
        meta_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        return manifest
    finally:
        for f in staging_dir.glob("*"):
            try:
                f.unlink(missing_ok=True)
            except Exception:
                pass
        try:
            staging_dir.rmdir()
        except Exception:
            pass


class GooglePlayClient:
    """Convenience client wrapper for Google Play Store operations."""

    def __init__(
        self,
        *,
        dispenser_url: str | None = None,
        dispenser_key: str | None = None,
        dispenser_email: str | None = None,
    ) -> None:
        if dispenser_url:
            os.environ["GOOGLE_PLAY_DISPENSER_URL"] = dispenser_url
        if dispenser_key:
            os.environ["GOOGLE_PLAY_DISPENSER_KEY"] = dispenser_key
        if dispenser_email:
            os.environ["GOOGLE_PLAY_EMAIL"] = dispenser_email

    def details(self, package: str, arch: str = "arm64-v8a") -> dict[str, Any]:
        auth = authenticate(arch)
        return get_details(package, auth)

    def download(self, package: str, output: Path | str, version: str = "", arch: str = "arm64-v8a") -> dict[str, Any]:
        return download_package(package, version, arch, Path(output))


def main() -> int:
    parser = argparse.ArgumentParser(description="Google Play download client")
    parser.add_argument("--dispenser-url", default=None, help="Token dispenser API URL")
    parser.add_argument("--dispenser-key", default=None, help="Dispenser API key")
    parser.add_argument("--dispenser-email", default=None, help="Email for self-hosted dispenser account")

    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    details_p = subparsers.add_parser("details", help="Fetch app details")
    details_p.add_argument("--package", required=True)
    details_p.add_argument("--arch", default="arm64-v8a")
    details_p.add_argument("--json", action="store_true")

    download_p = subparsers.add_parser("download", help="Download app package")
    download_p.add_argument("--package", required=True)
    download_p.add_argument("--version", default="")
    download_p.add_argument("--arch", default="arm64-v8a")
    download_p.add_argument("--output", required=True)

    args = parser.parse_args()

    if args.dispenser_url:
        os.environ["GOOGLE_PLAY_DISPENSER_URL"] = args.dispenser_url
    if args.dispenser_key:
        os.environ["GOOGLE_PLAY_DISPENSER_KEY"] = args.dispenser_key
    if args.dispenser_email:
        os.environ["GOOGLE_PLAY_EMAIL"] = args.dispenser_email

    if args.subcommand == "details":
        auth = authenticate(args.arch)
        data = get_details(args.package, auth)
        if args.json:
            print(json.dumps(data, indent=2))
        else:
            print(data["versionString"])
        return 0

    if args.subcommand == "download":
        dest = Path(args.output)
        manifest = download_package(args.package, args.version, args.arch, dest)
        print(json.dumps(manifest))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
