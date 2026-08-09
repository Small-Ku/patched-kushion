# patched-kushion

patched-kushion publishes patched Android apps, root modules, and a
signed F-Droid-compatible repository. Patched apps use stable package identities
so their update channel does not have to change when the underlying patch bundle
changes. Selected external APKs are mirrored without modification and retain
their upstream signatures.

## Install

### F-Droid-compatible client (recommended for non-root apps)

1. Open the [`fdroid` branch](../../tree/fdroid).
2. Copy the repository URL shown there. The generated URL includes the F-Droid
   repository key fingerprint; keep the fingerprint when adding the source.
3. Add that URL as a repository in your F-Droid-compatible client, refresh its
   indexes, then install the app you want.

The `fdroid` branch is created by the publishing workflow, so it is available
after the repository has been published at least once. The canonical repository
currently uses `raw.githubusercontent.com`; CDN/storage changes are intentionally
kept separate from the client-facing package and signing model.

### GitHub Releases

[GitHub Releases](../../releases) contain the patched APKs and root module ZIPs
produced by this repository. For non-root use, prefer the F-Droid repository so
updates remain attached to its signed index and provenance data.

KouTube and KouMusik require **MicroG RE** for non-root Google sign-in and Google
services. MicroG RE is mirrored in the same F-Droid repository as an unchanged,
upstream-signed APK.

## Patched apps

Each logical app has one primary stable non-root package identity. The package
name belongs to patched-kushion rather than to the current patch project, so a
future patch-family migration does not force users onto a new Android package.
Root modules continue to use the official upstream package name.

<!-- BEGIN APP CATALOG -->
| App | Stable non-root package | Current patch bundle | Build target |
|---|---|---|---|
| KouMusik | `de.kwoo.shion.music` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `Music-Morphe` |
| KouPhotos | `de.kwoo.shion.photos` | [De-Vanced](https://github.com/RookieEnough/De-Vanced) | `GooglePhotos-DeVanced` |
| KouTube | `de.kwoo.shion.youtube` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `YouTube-Morphe` |
<!-- END APP CATALOG -->

The source of truth is [`package-identities.toml`](package-identities.toml).
See [`docs/app-identities.md`](docs/app-identities.md) for the identity and
migration rules.

## Unmodified upstream mirrors

The F-Droid repository also imports selected GitHub Release APKs. These files
are not renamed, patched, or re-signed by patched-kushion.

| App | Upstream | Repository behavior |
|---|---|---|
| MicroG RE | [MorpheApp/MicroG-RE](https://github.com/MorpheApp/MicroG-RE) | Stable releases; upstream APK signature is pinned |
| sing-box for Android | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | Stable and prerelease versions; architecture-specific and universal APKs; upstream signature is pinned |

The exact source rules and signer certificate pins live in
[`fdroid/sources.toml`](fdroid/sources.toml).

## Root modules

Root module ZIPs are distributed through [GitHub Releases](../../releases), not
through F-Droid. They are intended for Magisk/KernelSU-style installations and
keep the original application package identity because they mount over or
replace the stock application.

If Play Store updates interfere with a YouTube or YouTube Music root module,
[zygisk-detach](https://github.com/j-hc/zygisk-detach) can detach the package
from Play Store updates. Users affected by classic mount problems can also
review [rvmm-zygisk-mount](https://github.com/j-hc/rvmm-zygisk-mount).

## Updates, signatures, and provenance

patched-kushion separates three identities:

- Patched non-root APKs are signed with this deployment's persistent
  patched-kushion package-signing key. Replacing that key breaks Android update
  compatibility with already-installed builds.
- Mirrored external APKs remain byte-for-byte upstream-signed. The importer pins
  their package name and signer certificate before publishing them.
- The F-Droid repository has its own independent signing key. Clients should use
  the repository URL containing that key's SHA-256 fingerprint.

Every successful F-Droid publication also writes `fdroid/provenance.json` on the
`fdroid` branch. It records the upstream repository/release asset, APK hash,
package/version, signer fingerprint, ABI information, and final repository
filename used for each imported APK.

See [`docs/package-signing.md`](docs/package-signing.md) for APK key management
and [`docs/fdroid.md`](docs/fdroid.md) for the repository signing and publishing
model.

## Build locally

Prerequisites are a Java 21 JDK/JRE, `git`, `curl`, `jq`, and `zip`. Clone this
repository, then create a local package-signing identity before the first build:

```sh
./scripts/generate-package-identity.sh
./build.sh
```

Generated private keys stay under the ignored `signing/` directory. Do not
publish builds made with an ephemeral key if you expect those APKs to receive
future in-place updates.

Build targets and patch selections are configured in [`config.toml`](config.toml).
For the inherited builder options and target schema, see [`CONFIG.md`](CONFIG.md).

### Termux

`build-termux.sh` remains available for the inherited Termux workflow, but it
still contains upstream-oriented bootstrap behavior. Prefer the normal local
build flow above unless you have reviewed and adapted that script for your fork.

## Maintain the F-Droid repository

The publishing pipeline is desired-state driven. Each `target × architecture ×
mode` build is an isolated matrix job; only missing or stale variants run, and
successful siblings are checkpointed even when another variant fails. F-Droid
has a separate provenance check, so a failed F-Droid publication is retried even
when no patched-app input changed. See [`docs/pipeline.md`](docs/pipeline.md) for
the planner, partial-retry, and checkpoint-recovery model.

For a new deployment, generate the independent F-Droid repository signing
identity once and add the two generated secret values to GitHub Actions:

```sh
./scripts/generate-fdroid-identity.sh
```

This creates `CONFIG_YML` and `KEYSTORE_P12` values under the ignored
`fdroid-signing/` directory. Back that directory up securely; replacing this key
changes the repository identity for existing clients.

To add another upstream GitHub Release source locally:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY
```

The helper inspects the release APK, verifies its signature, obtains the package
name and certificate SHA-256 fingerprint, and writes a pinned source entry for
review. Full setup and recovery instructions are in
[`docs/fdroid.md`](docs/fdroid.md).

## Licensing and notices

This repository retains the GPLv3 license of the builder it is based on,
[j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module).
Patch projects and mirrored applications keep their own licenses and trademarks.

Production builds use Morphe Desktop with Morphe-compatible `.mpp` patch bundles.
No build or update path depends on ReVanced repositories or ReVanced release APIs.
The `app.revanced.android.gms` name used by MicroG RE is an Android package identity,
not a repository or service dependency.

KouTube and KouMusik currently use `MorpheApp/morphe-patches`. Their derivative
artifacts include the Morphe notice required by that patch license, and the same
text is preserved in [`NOTICE`](NOTICE). These builds are patched-kushion builds,
not official Morphe releases and not affiliated with Morphe.

External mirrored APKs, including MicroG RE and sing-box, are distributed
unchanged from their respective upstream releases and retain their upstream
package identity and signature.
