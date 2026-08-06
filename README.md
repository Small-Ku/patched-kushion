# ReVanced Magisk Module
[![Telegram](https://img.shields.io/badge/Telegram-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/rvc_magisk)
[![CI](https://github.com/j-hc/revanced-magisk-module/actions/workflows/ci.yml/badge.svg?event=schedule)](https://github.com/j-hc/revanced-magisk-module/actions/workflows/ci.yml)

Extensive ReVanced builder  

## Stable non-root app identities

patched-kushion gives one primary non-root build per logical app a stable package
identity. The package does not encode the current patch family, so switching the
implementation later does not force users to install a different app. Root
modules keep the official package name, and externally mirrored APKs are never
modified.

<!-- BEGIN APP CATALOG -->
| App | Stable non-root package | Current patch bundle | Build target |
|---|---|---|---|
| KouMusik | `de.kwoo.shion.music` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `Music-Morphe` |
| KouPhotos | `de.kwoo.shion.photos` | [De-Vanced](https://github.com/RookieEnough/De-Vanced) | `GooglePhotos-DeVanced` |
| KouTube | `de.kwoo.shion.youtube` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `YouTube-Morphe` |
<!-- END APP CATALOG -->

The source of truth is [`package-identities.toml`](package-identities.toml).
Current patch bundles are also shown in release notes and F-Droid app
descriptions. See [`docs/app-identities.md`](docs/app-identities.md).

Get the [latest CI release](https://github.com/j-hc/revanced-magisk-module/releases).

Use [**zygisk-detach**](https://github.com/j-hc/zygisk-detach) to detach YouTube and YT Music from Play Store if you are using magisk modules. 

<details><summary><big>Features</big></summary>
<ul>
 <li> Supports all present and future ReVanced apps (including projects implementing the same API)</li>
 <li> Can build Magisk modules and non-root APKs</li>
 <li> Updated daily with the latest versions of apps and patches</li>
 <li> Optimizes APKs and modules for size</li>
 <li> Modules</li>
    <ul>
     <li> recompile invalidated odex for faster usage</li>
     <li> receive updates from Magisk app</li>
     <li> do not break safetynet or trigger root detections</li>
     <li> handle installation of the correct version of the stock app and all that</li>
     <li> support Magisk and KernelSU</li>
    </ul>
</ul>
</details>

## To include/exclude patches or patch other apps

 * Star the repo :eyes:
 * Use the repo as a [template](https://github.com/new?template_name=revanced-magisk-module&template_owner=j-hc)
 * Customize [`config.toml`](./config.toml) using [rvmm-config-gen](https://j-hc.github.io/rvmm-config-gen/)
 * Run the build [workflow](../../actions/workflows/build.yml)
 * Grab your modules and APKs from [releases](../../releases)

also see here [`CONFIG.md`](./CONFIG.md)

## If you are having trouble with the classic mount method of the modules
such as,
- **"Reflash needed"** error after reboots
- **"Suspicious mount detected"** warnings from root detector apps

You can consider using [rvmm-zygisk-mount](https://github.com/j-hc/rvmm-zygisk-mount)

## Building Locally
### On Termux
```console
bash <(curl -sSf https://raw.githubusercontent.com/j-hc/revanced-magisk-module/main/build-termux.sh)
```

### On Linux
```console
$ git clone https://github.com/j-hc/revanced-magisk-module --depth 1
$ cd revanced-magisk-module
$ ./scripts/generate-package-identity.sh
$ ./build.sh
```

The generated APK signing identity stays in the ignored `signing/` directory.
See [`docs/package-signing.md`](docs/package-signing.md) before publishing builds
or configuring GitHub Actions.

## Google Photos with De-Vanced

`config.toml` includes a separate `GooglePhotos-DeVanced` target. It uses the
`RookieEnough/De-Vanced` patch bundle with `MorpheApp/morphe-cli` and currently
owns the stable `de.kwoo.shion.photos` non-root channel. The existing
`GooglePhotos` target remains available as an alternative implementation, but
changing the primary target in `package-identities.toml` does not change the
stable package identity.

## F-Droid repository

APK release assets can also be published as a signed F-Droid repository. The
workflow stores generated APKs and indexes on the `fdroid` branch; Magisk and
KernelSU module ZIPs remain on GitHub Releases. `fdroid/sources.toml` may also
pin and automatically import APKs from other GitHub Release repositories.

Use `scripts/add-fdroid-source.sh OWNER/REPOSITORY` to inspect and add an
external source. See [`docs/fdroid.md`](docs/fdroid.md) for signing-secret
setup, source validation, private repositories, automatic updates, repository
URL, and fingerprint configuration.
