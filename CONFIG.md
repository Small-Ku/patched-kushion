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
forward-compatibility-probes = 2
enable-aptoide = true
enable-apkpure = true
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
If the primary patch bundle intentionally has no universal clone patch, `identity-patches-source` can name an auxiliary bundle used for a second, APK-only identity pass. The auxiliary bundle is fingerprinted by the workflow planner so a new identity-patch release invalidates cached/reused APKs. Root modules never run the auxiliary identity pass and keep the upstream package name.

### Per-app build options

```toml
[apps.SomeApp.build]
enabled = true
build-mode = "apk"       # apk, module, or both
version = "auto"         # auto, latest, beta, or an explicit version
forward-compatibility-probes = 2 # auto only; provider-advertised newer versions to try

patches-source = "OWNER/PATCH_REPOSITORY"
cli-source = "OWNER/CLI_REPOSITORY"
patch-brand = "Patch Brand"
patches-version = "latest"
cli-version = "latest"

# Optional second patch bundle used only when the primary bundle has no
# compatible Clone app/package-name patch for the stable non-root identity.
identity-patches-source = "MorpheApp/morphe-patches"
identity-patches-version = "latest"

patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

# Optional post-patch launcher branding. The icon overlay is a directory or
# zip whose files are rooted at res/... and are copied over decoded resources.
launcher-name = "Kou Example"
launcher-icon-overlay = "branding/example"

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

# Package-derived source adapters. Both default to the global [build] value.
enable-aptoide = true
enable-apkpure = true

module-prop-name = "some-app-module"
dpi = "360-480dpi"
arch = "arm64-v8a"
```

If a patch name contains a single quote, write the quote twice inside a TOML single-quoted string.

`version = "auto"` starts from the versions declared compatible by the selected patches. Source discovery may additionally try up to `forward-compatibility-probes` newer versions, but only when a configured provider actually advertises them. These forward probes are independent matrix nodes: failure does not replace or suppress declared-compatible builds. Set the value to `0` globally or per app to disable upward probing. `latest`, `beta`, and explicit versions do not use forward probes.
`latest` selects the newest stable upstream version without patch compatibility filtering.
`beta` also permits beta and alpha versions.

### Stock source policy

`enable-aptoide` and `enable-apkpure` default to `true`. They are package-derived source adapters, so an app only needs a correct `upstream-package`; no Aptoide/APKPure URL is stored in the app table. Aptoide contributes lightweight current-version/direct-APK metadata and payload nodes. APKPure is accessed through the pinned EFF `apkeep` helper and contributes exact historical-version and multi-ABI nodes. Automatically downloaded `apkeep` binaries are selected from the pinned release and verified against the SHA-256 digest in GitHub release metadata before execution. APKFab is an explicit per-app adapter configured with `apkfab-dlurl`; it inventories exact historical variants and may materialize only the requested ABI branch. APKFab device-profile XAPKs are deliberately excluded from broad/universal acquisition because a single profile may contain only one density/configuration subset.

CI source acquisition is graph-planned rather than a fixed provider fallback chain. Before downloading stock payloads, `Source` probes every configured provider for version metadata and writes `source-graph.json`. The graph contains the patch-declared candidates from `Plan` plus the bounded, provider-advertised forward probes described above. Candidate versions acquire independently in parallel. For each version node, reusable broad/BUNDLE acquisition nodes are considered before per-ABI branch nodes. Provider preference is only a tie-breaker inside the graph, not the control flow.

A metadata endpoint may fail even when an exact-version payload URL still works, so failed/opaque discoveries remain explicit low-priority probe nodes instead of disappearing silently. Explicit mirror URLs remain useful candidates, but no Archive or APKMirror URL is required when a package-derived source can provide the requested stock. Every patched app must pin its upstream signing certificate. Third-party stores and mirrors are treated only as byte transports: an unpinned package is refused, and a signer/security failure advances to another graph path rather than terminating the whole target immediately.

`[stock-security]` controls the defense-in-depth checks applied after signing-certificate verification:

```toml
[stock-security]
cross-source-verification = "opportunistic"
deny-sha256 = ["..."]
deny-indicators = ["..."]
```

The normalized stock APK receives a security fingerprint containing package/version metadata, permissions, manifest components, DEX hashes, and native-library hashes. Configured known-bad artifact hashes and byte indicators are hard quarantine rules. Every non-direct transport—Aptoide, APKPure, APKFab, Uptodown, Internet Archive, and APKMirror—opportunistically asks another independently configured source for the same version/architecture. A matching core fingerprint is recorded as `matched`; no second source is `unavailable` and does not override a valid signer pin; an actual fingerprint disagreement is quarantined instead of guessing which mirror is correct. Sources are deduplicated by provenance family/domain before they count as independent corroboration, so two downloader paths backed by the same provider do not create a fake quorum. Explicit direct/upstream input is the only primary class that does not trigger another network request solely for corroboration.

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

APKM, APKS, and XAPK inputs use the same normalization path. For each candidate version, the source DAG exposes broad-container nodes before architecture-specific nodes. Metadata evidence determines which providers are tried first; configured providers whose listing endpoint is unavailable remain explicit probe nodes instead of silently disappearing. APKMirror can inventory a whole release page and rank BUNDLE variants by requested-ABI coverage, overall ABI breadth, minimum Android version, and density breadth; APKPure/apkeep can request several ABIs in one exact-version acquisition; APKFab can contribute an exact-version XAPK only to the matching ABI branch. Direct, Uptodown, and Archive candidates participate in the same graph rather than occupying fixed fallback positions. When no explicit `dpi` is configured, range descriptors such as `120-640dpi` remain eligible.

The selected container is partitioned once into common and ABI-specific split buckets. Architecture jobs download only their required buckets and merge them independently, so language/density payloads are shared rather than repeatedly downloaded from upstream.

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

The array form permits certificate rotation. A new mirror-observed certificate must not be learned automatically: add a new pin only after independently validating the upstream signing lineage. Runtime acquisition refuses unpinned third-party sources before their APK can enter the patch pipeline.

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

### Launcher branding

`launcher-name` rewrites the application label and every MAIN/LAUNCHER activity label after Morphe finishes patching. `launcher-icon-overlay` may point to a directory or `.zip` containing exact `res/...` resource replacements, including adaptive-icon XML, foreground/background drawables, and density-specific PNG/WebP assets. The overlay cannot modify files outside `res/`. APKEditor decodes with raw dex preservation (`-dex`) and rebuilds the APK before the normal notice, alignment, and signing gates.

Because launcher branding is part of the builder fingerprint, changing the name, overlay, or overlay files invalidates reuse of an older patched asset.
