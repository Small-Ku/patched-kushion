# Stable app identities

`config.toml` defines every application once under `[apps]`.
A patched app keeps its stable non-root package identity at app level and its patch recipe under `.build`.

Example:

```toml
[apps.KouPhotos]
display-name = "KnitPhotos"
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

The five patched APK targets use a same-source Kushion Patches pass for Knit launcher branding. KouPhotos applies its distribution identity in the same invocation. Its final validation also checks the Mars provider authority and linked intent host. See [KouPhotos identity](kouphotos-identity.md) for that distribution contract.

The builder searches for `aapt2` in this order:

1. `AAPT2` environment variable.
2. `PATH`.
3. Repository prebuilts.
4. Android SDK `build-tools`.

Root modules keep the upstream package name and may be configured independently from the stable non-root/F-Droid identity catalog.
Apps with `.release` also keep their upstream package name and signature because they are mirrored without repackaging.

## One app, one implementation

Each `[apps.<name>]` entry defines exactly one implementation:

```text
.build    patched by this repository
.release  mirrored unchanged from GitHub Releases
```

There is no separate target catalog.
The app key itself is the build target used by the workflow matrix.

Current internal targets, user-visible names, and stable non-root package identities are:

```text
KouInstagram -> Knitstagram   -> de.kwoo.shion.instagram
KouMessenger -> KnitMessenger -> de.kwoo.shion.messenger
KouMusik     -> KnitMusic     -> de.kwoo.shion.music
KouPhotos    -> KnitPhotos    -> de.kwoo.shion.photos
KouTube      -> KnitTube      -> de.kwoo.shion.youtube
```

The existing Kou* keys remain workflow target identifiers. Launcher names do not define package identity.


`scripts/app_catalog.py validate` verifies the patched app catalog.
The validation workflow also verifies that the README app table matches `config.toml`.

## Migration rule

A new `de.kwoo.shion.*` package is a different Android app from an old package name.
Users of the old package must install the new package separately.

After publication, do not change a stable package name and do not replace its APK signing key.
