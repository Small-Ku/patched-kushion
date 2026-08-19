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
| App | Stable non-root package | Current patch bundle |
|---|---|---|
| KouInstagram | `de.kwoo.shion.instagram` | [Piko](https://github.com/crimera/piko) |
| KouMessenger | `de.kwoo.shion.messenger` | [De-Vanced](https://github.com/RookieEnough/De-Vanced) |
| KouMusik | `de.kwoo.shion.music` | [Morphe](https://github.com/MorpheApp/morphe-patches) |
| KouPhotos | `de.kwoo.shion.photos` | [De-Vanced](https://github.com/RookieEnough/De-Vanced) |
| KouTube | `de.kwoo.shion.youtube` | [Morphe](https://github.com/MorpheApp/morphe-patches) |
<!-- END APP CATALOG -->

[`config.toml`](config.toml) is the source of truth for app identities and build/release behavior.
See [`docs/app-identities.md`](docs/app-identities.md) for the identity rules.

## External APK sources

The F-Droid repository also imports selected GitHub Release APKs.
patched-kushion does not patch, rename, or re-sign these APKs.

| App | Upstream | Repository behavior |
|---|---|---|
| MicroG RE | [MorpheApp/MicroG-RE](https://github.com/MorpheApp/MicroG-RE) | Stable releases; pinned upstream APK signature |
| sing-box for Android | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) | Stable and prerelease versions; ABI-specific and universal APKs; pinned upstream APK signature |

External release rules and certificate pins live with each app in [`config.toml`](config.toml).

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

Install Java 21, `git`, `curl`, `jq`, `zip`, and Android SDK Build Tools with `zipalign`.
The builder resolves `zipalign` from `ZIPALIGN`, `PATH`, or the newest installed SDK build-tools directory.
Then create a package-signing identity and run the build.

```sh
./scripts/generate-package-identity.sh
./build.sh
```

The generators store private keys under the ignored `signing/package/` and `signing/fdroid/` directories.
Back up the keys if you publish the generated APKs.

Use [`config.toml`](config.toml) to configure apps, patch builds, external releases, and F-Droid policy.
See [`CONFIG.md`](CONFIG.md) for the schema and build options.

### Termux

`build-termux.sh` supports the inherited Termux build path.
Review the script before you use it in a fork.
For normal local builds, use `build.sh`.

## Maintain the repository

The `Update` workflow resolves the patch-declared version set and separates architecture policy from concrete artifacts. Patched apps without an explicit architecture use the auto policy: request a real `universal` output plus all four supported ABI splits, then publish every variant that current stock sources can actually produce. Explicit `arches` remain hard requirements. Source selection is graph-planned: before any APK payload transfer, Source probes every configured provider for version metadata and persists the resulting search DAG as `source-graph.json`. For `version = "auto"`, the graph may also admit a bounded number of provider-advertised versions newer than the patch bundle's declared compatibility boundary as independent forward-compatibility probes. Every candidate version is acquired and patched independently, so a failed newer probe cannot suppress a declared known-good version. Within a version, broad Bundle/APKM/APKS/XAPK nodes are evaluated before architecture-specific acquisition nodes. Provider ordering is only a tie-breaker, not a first-success fallback chain. Every downloaded APK or split must still match the pinned upstream signer. Third-party stores are untrusted transport: acquired stock also receives package/version/permission/component/DEX/native security checks, configured IoCs are quarantined, and independent provenance is corroborated opportunistically when comparable.
For split-distributed stock apps, a broad reusable payload is preferred when it can cover more of the requested DAG. APKMirror release inventory can be scored before binary transfer; APKPure/apkeep can issue multi-ABI exact-version requests; Archive, Uptodown, and explicit direct inputs remain graph nodes when their metadata or exact-version endpoints can satisfy the request. A selected broad container is downloaded once and partitioned once into common splits plus ABI buckets. ABI-specific branches keep the base APK, requested ABI split, and every non-ABI split before APKEditor performs the unsigned Stock merge; the universal branch keeps the complete coherent split set. Runtime support is deliberately separate from derivability: a flattened multi-ABI standalone APK supplies only `universal`, never synthetic ABI branches. Partial broad results are retained while missing ABIs continue through other providers, and branch acquisition prefers validated split containers over larger flattened APKs. This preserves language, density, feature, and other configuration coverage while ABI-specific outputs remove only foreign CPU ABIs.
The Update workflow therefore fans out from one metadata-discovery DAG per app into independent `version × architecture × mode` branches. Successful declared and forward-compatible versions can coexist in the same GitHub Release. The release state keeps the newest compatible result as the preferred variant and also keeps an `inputId` ledger for every published compatible result, so later runs reuse the exact same build input instead of repeating merge/patch/package work. Architecture jobs never restart provider discovery or network fallback loops.
A missing auto-discovered ABI is recorded as unavailable rather than failed and is probed again on later runs. Candidate source/stock/patch failures are recorded as DAG results rather than multiplying red downstream jobs; after all candidates finish, final publication health fails once if a required output is still unsatisfied.
A failed required variant does not cancel successful variants, and a later run retries only the variants that still need work.

F-Droid has a separate state check. Newly uploaded built APKs are handed directly from Release publication to that check, while the normal Release-API/provenance comparison remains as a fallback comparison for external and previously missed changes.
Any GitHub Release APK larger than 100 MiB is left on its Release but omitted from the Git-backed F-Droid branch, including external sources such as sing-box; there are no app-specific filename exclusions.
A failed F-Droid publication can retry even when no app input changed.
See [`docs/pipeline.md`](docs/pipeline.md) for the update flow.

Create the F-Droid repository identity once:

```sh
./scripts/generate-fdroid-identity.sh
```

Set the generated `CONFIG_YML` and `KEYSTORE_P12` values as GitHub Actions repository secrets.
Back up the ignored `signing/fdroid/` directory.

Add an external GitHub Release app with:

```sh
./scripts/add-release-app.sh OWNER/REPOSITORY
```

See [`docs/fdroid.md`](docs/fdroid.md) for setup, release rules, and recovery.

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
