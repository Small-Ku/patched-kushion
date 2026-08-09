# patched-kushion

patched-kushion publishes patched Android apps, root modules, and a signed F-Droid repository.
Patched non-root apps use stable package identities.
Selected external APKs keep their upstream package identity and signature.

## Install non-root apps

Use an F-Droid-compatible client for normal non-root installation.

1. Open the [`fdroid` branch](../../tree/fdroid).
2. Copy the repository URL from that branch.
3. Keep the SHA-256 fingerprint in the URL.
4. Add the URL to your F-Droid-compatible client.
5. Refresh the repository.
6. Install the app that you want.

The `fdroid` branch exists after the first successful F-Droid publication.
The current repository URL uses `raw.githubusercontent.com`.

You can also get patched APKs and root module ZIPs from [GitHub Releases](../../releases).
For non-root apps, prefer F-Droid because it provides signed repository indexes and provenance data.

KouTube and KouMusik need **MicroG RE** for non-root Google sign-in and Google services.
The same F-Droid repository provides an unchanged upstream-signed MicroG RE APK.

## Patched apps

Each patched non-root app has one stable package identity.
A patch bundle change does not require a package-name change.
Root modules keep the official upstream package name.

<!-- BEGIN APP CATALOG -->
| App | Stable non-root package | Current patch bundle | Build target |
|---|---|---|---|
| KouMusik | `de.kwoo.shion.music` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `Music-Morphe` |
| KouPhotos | `de.kwoo.shion.photos` | [De-Vanced](https://github.com/RookieEnough/De-Vanced) | `GooglePhotos-DeVanced` |
| KouTube | `de.kwoo.shion.youtube` | [Morphe](https://github.com/MorpheApp/morphe-patches) | `YouTube-Morphe` |
<!-- END APP CATALOG -->

[`package-identities.toml`](package-identities.toml) is the source of truth.
See [`docs/app-identities.md`](docs/app-identities.md) for the identity rules.

## External APK sources

The F-Droid repository also imports selected GitHub Release APKs.
patched-kushion does not patch, rename, or re-sign these APKs.

| App | Upstream | Repository behavior |
|---|---|---|
| MicroG RE | [MorpheApp/MicroG-RE](https://github.com/MorpheApp/MicroG-RE) | Stable releases; pinned upstream APK signature |
| sing-box for Android | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | Stable and prerelease versions; ABI-specific and universal APKs; pinned upstream APK signature |

[`fdroid/sources.toml`](fdroid/sources.toml) contains the source rules and certificate pins.

## Root modules

GitHub Releases provide root module ZIPs.
F-Droid does not publish these ZIPs.

Root modules keep the upstream package name because they replace or mount over the stock app.

If Play Store updates interfere with a YouTube or YouTube Music module, use [zygisk-detach](https://github.com/j-hc/zygisk-detach).
For mount problems, see [rvmm-zygisk-mount](https://github.com/j-hc/rvmm-zygisk-mount).

## Trust model

patched-kushion uses three separate signing identities.

- The package-signing key signs patched non-root APKs.
- Upstream signing keys remain on external mirrored APKs.
- The F-Droid repository key signs the repository indexes.

Do not replace the package-signing key after you publish an app.
A new key prevents an installed app from accepting an in-place update.

Do not replace the F-Droid repository key after users add the repository.
A new key creates a different repository identity for those users.

Each successful F-Droid publication writes `fdroid/provenance.json` to the `fdroid` branch.
The file records the source asset, APK hash, package, version, signer, ABI list, and repository file name.

See [`docs/package-signing.md`](docs/package-signing.md) for APK signing.
See [`docs/fdroid.md`](docs/fdroid.md) for F-Droid signing and publication.

## Build locally

Install Java 21, `git`, `curl`, `jq`, and `zip`.
Then create a package-signing identity and run the build.

```sh
./scripts/generate-package-identity.sh
./build.sh
```

The generator stores private keys in the ignored `signing/` directory.
Back up the keys if you publish the generated APKs.

Use [`config.toml`](config.toml) to select targets and patches.
See [`CONFIG.md`](CONFIG.md) for the target options.

### Termux

`build-termux.sh` supports the inherited Termux build path.
Review the script before you use it in a fork.
For normal local builds, use `build.sh`.

## Maintain the repository

The `Update` workflow resolves the patch-supported app version and separates architecture policy from concrete artifacts. Targets without an explicit architecture use the auto policy: probe a real `universal` output plus all four supported ABI splits, then publish every variant that current stock sources can produce. Explicit `arches` remain hard requirements. Stock mirrors are fallback sources, not architecture authorities, so a late archive mirror does not suppress another source.
For split-distributed stock apps, ABI-specific builds keep the base APK, the requested ABI split, and every non-ABI split before APKEditor merges the set. The universal build keeps the complete coherent split set. This preserves language, density, and feature coverage while ABI-specific outputs remove only foreign CPU ABIs.
Each `target × architecture × mode` variant runs in an isolated matrix job.
A missing auto-discovered ABI is recorded as unavailable rather than failed and is probed again on later runs; patching, signing, or identity failures still fail that job.
A failed required variant does not cancel successful variants, and a later run retries only the variants that still need work.

F-Droid has a separate state check.
Any GitHub Release APK larger than 100 MiB is left on its Release but omitted from the Git-backed F-Droid branch, including external sources such as sing-box; there are no app-specific filename exclusions.
A failed F-Droid publication can retry even when no app input changed.
See [`docs/pipeline.md`](docs/pipeline.md) for the update flow.

Create the F-Droid repository identity once:

```sh
./scripts/generate-fdroid-identity.sh
```

Set the generated `CONFIG_YML` and `KEYSTORE_P12` values as GitHub Actions repository secrets.
Back up the ignored `fdroid-signing/` directory.

Add an external GitHub Release source with:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY
```

See [`docs/fdroid.md`](docs/fdroid.md) for setup, source rules, and recovery.

## Writing style

Project documentation and workflow labels use a controlled technical style based on ASD-STE100.
The project does not claim formal ASD-STE100 compliance.
See [`docs/writing-style.md`](docs/writing-style.md).

## Licenses and notices

This repository keeps the GPLv3 license of its builder base, [j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module).
Patch projects and mirrored apps keep their own licenses and trademarks.

Production builds use Morphe Desktop and Morphe-compatible `.mpp` patch bundles.
No build or update path uses a ReVanced repository or ReVanced release API.
`app.revanced.android.gms` is a MicroG RE Android package name, not a repository dependency.

KouTube and KouMusik use `MorpheApp/morphe-patches`.
Their derivative artifacts include the required Morphe notice.
The repository also keeps this text in [`NOTICE`](NOTICE).
These builds are not official Morphe releases.

External APKs such as MicroG RE and sing-box remain unchanged.
They keep their upstream package identity and signature.
