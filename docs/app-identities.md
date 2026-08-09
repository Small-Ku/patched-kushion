# Stable app identities

`config.toml` defines every application once under `[apps]`.
A patched app keeps its stable non-root package identity at app level and its patch recipe under `.build`.

Example:

```toml
[apps.KouPhotos]
display-name = "KouPhotos"
package-name = "de.kwoo.shion.photos"
upstream-package = "com.google.android.apps.photos"

[apps.KouPhotos.build]
patches-source = "RookieEnough/De-Vanced"
patch-brand = "De-Vanced"
build-mode = "both"
```

The package name identifies the patched-kushion update channel.
It does not identify the current patch project.
Changing the patch bundle does not require changing the stable package name.

## Scope

For a patched app, the builder:

1. Resolves the stock APK from `upstream-package`.
2. Enables the compatible package-name patch.
3. Sets it to the stable `package-name`.
4. Builds and signs the non-root APK.
5. Reads the completed package name with `aapt2`.
6. Rejects the APK if the package name is wrong.

Current Morphe bundles use `Clone app` for package identity.
Older compatible bundles can use `Change package name`.
The builder also manages the GmsCore or MicroG patch when the selected patch bundle requires it.

The builder searches for `aapt2` in this order:

1. `AAPT2` environment variable.
2. `PATH`.
3. Repository prebuilts.
4. Android SDK `build-tools`.

Root modules keep the upstream package name.
Apps with `.release` also keep their upstream package name and signature because they are mirrored without repackaging.

## One app, one implementation

Each `[apps.<name>]` entry defines exactly one implementation:

```text
.build    patched by this repository
.release  mirrored unchanged from GitHub Releases
```

There is no separate target catalog.
The app key itself is the build target used by the workflow matrix.

Current patched identities are:

```text
KouTube   -> de.kwoo.shion.youtube
KouMusik  -> de.kwoo.shion.music
KouPhotos -> de.kwoo.shion.photos
```

`scripts/app_catalog.py validate` verifies the patched app catalog.
The validation workflow also verifies that the README app table matches `config.toml`.

## Migration rule

A new `de.kwoo.shion.*` package is a different Android app from an old package name.
Users of the old package must install the new package separately.

After publication, do not change a stable package name and do not replace its APK signing key.
