# Build configuration

patched-kushion uses Morphe-compatible patches by default.
Add a target to `config.toml` to build another supported app.

Example:

```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
```

You can use Uptodown instead:

```toml
[Some-App]
uptodown-dlurl = "https://app.en.uptodown.com/android"
```

> [!WARNING]
> If a patch name contains a single quote, write the quote twice inside the TOML string.

Example: `'Hide ''Get Music Premium'''`.

## Global options

All global keys are optional.
These values are the defaults:

```toml
parallel-jobs = 1
compression-level = 9
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-desktop"
patch-brand = "Morphe"
patches-version = "latest"
cli-version = "latest"
```

`patches-source` must provide Morphe-compatible `.mpp` release assets.
`cli-source` must provide a Morphe Desktop command-line `.jar`.
A target can override these values.

## Target options

```toml
[Some-App]
app-name = "SomeApp"
enabled = true
build-mode = "apk"       # apk, module, or both
version = "auto"         # auto, latest, beta, or an explicit version

patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """
included-patches = "'Some Patch'"
exclusive-patches = false

include-stock = "merged" # merged, split, or disable for root modules
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://app.en.uptodown.com/android"
direct-dlurl = "https://website/com.example.app-1.2.3-all.apk"

module-prop-name = "some-app-module"
dpi = "360-480dpi"
arch = "arm64-v8a"       # arm64-v8a, arm-v7a, x86_64, x86, all, or both
```

`version = "auto"` selects the newest version that the selected patches support.
`version = "latest"` selects the latest stable app version without patch compatibility filtering.
`version = "beta"` also permits beta and alpha app versions.

Use `arches` when one target must build more than one architecture set:

```toml
arches = ["all", "arm64-v8a", "arm-v7a"]
```

`all` means the universal or multi-ABI APK.
If `arches` exists, it replaces `arch` for that target.

The builder manages the GmsCore or MicroG patch for non-root APKs.
It disables that patch for root modules.

For targets in `package-identities.toml`, the builder also manages `Clone app` or its compatible package-name patch.
Do not set `-OpackageName` manually for these targets.

## Alternative patch bundles

A target can use another Morphe-compatible `.mpp` bundle.
It can still use Morphe Desktop as the patcher.

KouPhotos uses this configuration:

```toml
[GooglePhotos-DeVanced]
app-name = "KouPhotos"
patches-source = "RookieEnough/De-Vanced"
patch-brand = "De-Vanced"
build-mode = "both"
arches = ["all", "arm64-v8a", "arm-v7a"]
apkmirror-dlurl = "https://www.apkmirror.com/apk/google-inc/photos/"
```

## Stable package identities

`package-identities.toml` contains the primary non-root package names.

Example:

```toml
[apps.KouPhotos]
target = "GooglePhotos-DeVanced"
package-name = "de.kwoo.shion.photos"
display-name = "KouPhotos"
upstream-package = "com.google.android.apps.photos"
```

You can change the target to another compatible patch bundle later.
Keep the stable package name unchanged.

Root modules and external mirrored APKs do not use this package-name change.
See [`docs/app-identities.md`](docs/app-identities.md).
