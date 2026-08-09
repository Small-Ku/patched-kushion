# Configuration

patched-kushion uses the Morphe patching ecosystem by default. Adding another
Morphe-compatible app only requires a download source when the default Morphe
patch bundle already supports it:

```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
# or uptodown-dlurl = "https://app.en.uptodown.com/android"
```

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string
> (for example, `'Hide ''Get Music Premium'''`).

## Global options

All global keys are optional. These are the current defaults:

```toml
parallel-jobs = 1
compression-level = 9
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-desktop"
patch-brand = "Morphe"
patches-version = "latest"
cli-version = "latest"
```

`patches-source` must publish Morphe-compatible `.mpp` release assets.
`cli-source` must publish the Morphe Desktop command-line `.jar`. Both may be
overridden per target when necessary.

## App options

```toml
[Some-App]
app-name = "SomeApp"     # release/display name; defaults to the table name
enabled = true           # whether to build this target
build-mode = "apk"       # "apk", "module", or "both"

# "auto" selects the newest version supported by the selected patches.
# "latest" selects the latest stable app version without compatibility filtering.
# "beta" also permits beta/alpha app versions.
version = "auto"

# Extra Morphe Desktop CLI arguments. Multiline TOML strings are supported.
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

include-stock = "merged" # "merged", "split", or "disable" for root modules
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://app.en.uptodown.com/android"
direct-dlurl = "https://website/com.example.app-1.2.3-all.apk"

module-prop-name = "some-app-module"
dpi = "360-480dpi"
arch = "arm64-v8a"       # arm64-v8a, arm-v7a, x86_64, x86, all, or both
```

The builder automatically enables the selected bundle's GmsCore/MicroG patch
for non-root APKs and disables it for root modules. Targets managed by
`package-identities.toml` also have their `Clone app`/package-name patch managed
automatically; do not pass `-OpackageName` manually for them.

## Alternative Morphe patch bundles

A target can use another `.mpp` bundle while keeping Morphe Desktop as the
shared patch frontend. KouPhotos currently does this with De-Vanced:

```toml
[GooglePhotos-DeVanced]
app-name = "KouPhotos"
patches-source = "RookieEnough/De-Vanced"
patch-brand = "De-Vanced"
build-mode = "both"
arch = "both"
apkmirror-dlurl = "https://www.apkmirror.com/apk/google-inc/photos/"
```

## Stable package identities

Primary non-root package names are configured separately in
[`package-identities.toml`](package-identities.toml):

```toml
[apps.KouPhotos]
target = "GooglePhotos-DeVanced"
package-name = "de.kwoo.shion.photos"
display-name = "KouPhotos"
upstream-package = "com.google.android.apps.photos"
```

The target may later move to another compatible patch bundle without changing
the Android package identity. Root modules and mirrored external APKs are never
renamed. See [`docs/app-identities.md`](docs/app-identities.md) for the identity
and coexistence rules.
