# Project configuration

`config.toml` is the single source of truth for patched-kushion application, build, external release, signature, and F-Droid policy.

The schema version is `config-version = 1`.
Each entry under `[apps]` represents one Android app and must define exactly one implementation:

- `[apps.<name>.build]` for an app patched by this repository.
- `[apps.<name>.release]` for an unchanged APK mirrored from GitHub Releases.

There is no separate target or F-Droid source catalog.

## Build defaults

Shared patch-build defaults live under `[build]`:

```toml
[build]
enable-module-update = true
parallel-jobs = 1
compression-level = 9
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-desktop"
patch-brand = "Morphe"
patches-version = "latest"
cli-version = "latest"
```

All keys are optional except that the table itself must exist.
A patched app can override patch bundle, CLI, brand, or version in its `.build` table.

## Patched apps

A patched non-root app keeps its stable published package name at app level.
The upstream package used for stock acquisition and patch compatibility is separate:

```toml
[apps.KouTube]
display-name = "KouTube"
package-name = "de.kwoo.shion.youtube"
upstream-package = "com.google.android.youtube"

[apps.KouTube.build]
build-mode = "both"
apkmirror-dlurl = "https://www.apkmirror.com/apk/google-inc/youtube"
uptodown-dlurl = "https://youtube.en.uptodown.com/android"
archive-dlurl = "https://archive.org/download/jhc-apks/apks/com.google.android.youtube"
```

`display-name` is optional and defaults to the app key.
For a non-root APK, `package-name` must use the stable `de.kwoo.shion.*` namespace.
Do not change a published stable package name.

The builder manages the compatible package-name patch (`Clone app` or `Change package name`) and verifies the final package with `aapt2`.
Root modules keep the upstream package name.

### Per-app build options

```toml
[apps.SomeApp.build]
enabled = true
build-mode = "apk"       # apk, module, or both
version = "auto"         # auto, latest, beta, or an explicit version

patches-source = "OWNER/PATCH_REPOSITORY"
cli-source = "OWNER/CLI_REPOSITORY"
patch-brand = "Patch Brand"
patches-version = "latest"
cli-version = "latest"

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
direct-dlurl = "https://example.invalid/app.apk"
archive-dlurl = "https://archive.example.invalid/app"

module-prop-name = "some-app-module"
dpi = "360-480dpi"
arch = "arm64-v8a"
```

If a patch name contains a single quote, write the quote twice inside a TOML single-quoted string.

`version = "auto"` selects the newest version supported by the selected patches.
`latest` selects the newest stable upstream version without patch compatibility filtering.
`beta` also permits beta and alpha versions.

### Architecture policy

If neither `arch` nor `arches` is set, the default is `arch = "auto"`.
Auto mode probes these outputs and publishes every one that current stock sources can produce:

```text
universal
arm64-v8a
arm-v7a
x86_64
x86
```

A missing auto variant is recorded as unavailable instead of failing the build.
It is probed again on later runs.

Use `arches` for explicit required outputs:

```toml
arches = ["arm64-v8a", "arm-v7a"]
```

`arch = "both"` is shorthand for the two ARM outputs.
Legacy scalar `arch = "all"` means the auto policy.
Legacy `"all"` inside `arches` is normalized to concrete `"universal"`.

A universal stock artifact can satisfy an architecture-specific output because the builder can derive the requested ABI from a universal APK or split container.

### Split containers

APKM, APKS, and XAPK inputs use the same normalization path. When a split container and a compatible standalone APK are both available, the builder prefers the split container so ABI filtering can remove only foreign CPU payloads. If `dpi` is not configured, range descriptors such as `120-640dpi` are accepted instead of being filtered out as non-`nodpi` variants.

For an architecture-specific build, the builder keeps:

```text
base/master APK
+ requested ABI split
+ every non-ABI split
```

Non-ABI splits include language, density, feature, and other configuration splits.
For a universal build, the builder keeps the coherent base/master install set plus all ABI and non-ABI splits before merging with APKEditor.

## External release apps

An external release app keeps its upstream package identity and signing key:

```toml
[apps.example]
display-name = "Example"
package-name = "org.example.app"

[apps.example.release]
repository = "OWNER/REPOSITORY"
asset-patterns = ["*-arm64-v8a.apk", "*-universal.apk"]
asset-exclude-patterns = ["*-legacy-*"]
release-limit = 5
include-prereleases = false
certificates = ["A1B2C3D4E5F60718..."]
```

`certificates` is a non-empty array of accepted APK signer SHA-256 fingerprints.
It supports signer rotation without repeating the package name in another table.

Optional release keys are:

```toml
token-env = "EXTERNAL_RELEASE_TOKEN"
max-asset-size = 52428800
```

For APK families where asset names declare ABI coverage, pin the expected native code list:

```toml
[apps.example.release.asset-native-codes]
"*-arm64-v8a.apk" = ["arm64-v8a"]
"*-universal.apk" = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
```

Use `./scripts/add-release-app.sh OWNER/REPOSITORY` to inspect a release and append a pinned external app definition.
One app entry represents one Android package; narrow `--pattern` if a release contains several packages.

## Stock APK signatures

`[upstream-signatures]` pins accepted stock APK certificates used by patched builds:

```toml
[upstream-signatures]
"com.google.android.youtube" = ["3d7a..."]
```

The array form permits certificate rotation.

## F-Droid policy

Repository-wide F-Droid behavior belongs under `[fdroid]`:

```toml
[fdroid]
max-repo-asset-size = 104857600
include-built-releases = true
built-release-limit = 10
```

`include-built-releases` imports patched APKs from this repository's own GitHub Releases.
`built-release-limit` controls how many of those releases are considered.
External release apps are discovered from `[apps.*.release]`; they are not duplicated under `[fdroid]`.

The 100 MiB limit matches GitHub's Git blob limit for the published `fdroid` branch.
An external app may set a lower `max-asset-size`, but it cannot relax the repository-wide limit.
