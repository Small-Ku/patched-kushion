from __future__ import annotations

import contextlib
import io
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RESOURCE_OUTPUT = """\
resource 0x7f110032 mipmap/knit_launcher
      () (file) res/mipmap/knit_launcher.xml type=XML
      (anydpi-v26) (file) res/mipmap-anydpi-v26/knit_launcher.xml type=XML
      (anydpi-v33) (file) res/mipmap-anydpi-v33/knit_launcher.xml type=XML
      () (file) res/drawable/knit_launcher_background.xml type=XML
      () (file) res/drawable/knit_launcher_foreground.xml type=XML
      () (file) res/drawable/knit_launcher_legacy_background.xml type=XML
      () (file) res/drawable/knit_launcher_monochrome.xml type=XML
"""


def manifest_output(package: str, name: str, icon: str = "@0x7f110032") -> str:
    return f"""\
N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    A: package="{package}" (Raw: "{package}")
    E: application (line=2)
      A: android:label(0x01010001)="{name}" (Raw: "{name}")
      A: android:icon(0x01010002)={icon}
      A: android:roundIcon(0x0101052c)={icon}
      E: activity (line=3)
        A: android:label(0x01010001)="{name}" (Raw: "{name}")
        A: android:icon(0x01010002)={icon}
        E: intent-filter (line=4)
          E: action (line=5)
            A: android:name(0x01010003)="android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")
          E: category (line=6)
            A: android:name(0x01010003)="android.intent.category.LAUNCHER" (Raw: "android.intent.category.LAUNCHER")
"""


def main() -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    import kushion_patches
    import validate_knit_branding

    config = tomllib.loads((ROOT / "config.toml").read_text())["apps"]
    expected_resources = (
        "drawable/knit_launcher_background.xml",
        "drawable/knit_launcher_foreground.xml",
        "drawable/knit_launcher_legacy_background.xml",
        "drawable/knit_launcher_monochrome.xml",
        "mipmap/knit_launcher.xml",
        "mipmap-anydpi-v26/knit_launcher.xml",
        "mipmap-anydpi-v33/knit_launcher.xml",
    )
    artwork = {"KouTube": "tube", "KouMusik": "music", "KouPhotos": "photos",
               "KouInstagram": "instagram", "KouMessenger": "messenger"}
    for target, (package, name) in kushion_patches.KNIT_TARGETS.items():
        assert config[target]["package-name"] == package
        assert config[target]["display-name"] == name
        assert kushion_patches.planned_bundle(target, "apk", package, None)["kind"] == "in-repo"
        assert kushion_patches.planned_bundle(target, "module", package, None) is None
        assert all((ROOT / "kushion-patches/patches/src/main/resources/knit" / artwork[target] / "res" / path).is_file()
                   for path in expected_resources)

    original_run = validate_knit_branding.run
    output = io.StringIO()
    try:
        for target, (package, name) in kushion_patches.KNIT_TARGETS.items():
            validate_knit_branding.run = lambda *command, p=package, n=name: (
                RESOURCE_OUTPUT if "resources" in command else manifest_output(p, n)
            )
            sys.argv = ["validate_knit_branding.py", "--apk", str(ROOT / "tests/fixture.apk"),
                        "--target", target, "--package", package, "--aapt", "aapt", "--aapt2", "aapt2"]
            # The validator checks that the artifact path exists before it calls aapt.
            fixture = ROOT / "tests/fixture.apk"
            fixture.write_bytes(b"fixture")
            with contextlib.redirect_stdout(output):
                validate_knit_branding.main()

        validate_knit_branding.run = lambda *command: (
            RESOURCE_OUTPUT if "resources" in command
            else manifest_output("de.kwoo.shion.music", "KouMusik")
        )
        sys.argv = ["validate_knit_branding.py", "--apk", str(fixture), "--target", "KouMusik",
                    "--package", "de.kwoo.shion.music", "--aapt", "aapt", "--aapt2", "aapt2"]
        try:
            validate_knit_branding.main()
        except SystemExit as exc:
            assert "application label mismatch" in str(exc)
        else:
            raise AssertionError("validator accepted a non-Knit launcher label")
        fixture.unlink()
    finally:
        validate_knit_branding.run = original_run
        if (ROOT / "tests/fixture.apk").exists():
            (ROOT / "tests/fixture.apk").unlink()
    assert all("Knit" in line for line in output.getvalue().splitlines())

    print("Knit package mapping, artwork presence, and fail-closed APK validator tests passed")


if __name__ == "__main__":
    main()
