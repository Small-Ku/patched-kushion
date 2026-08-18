# F-Droid repository

The `Publish F-Droid` workflow publishes a signed repository on the `fdroid` branch.
It contains patched APKs built by this repository and selected unchanged APKs from external GitHub Releases.
Root module ZIP files are not published to F-Droid.

## Application sources

`config.toml` is the only application catalog.

A patched app uses `.build`:

```toml
[apps.KouTube]
package-name = "de.kwoo.shion.youtube"
upstream-package = "com.google.android.youtube"

[apps.KouTube.build]
build-mode = "both"
```

An unchanged external app uses `.release`:

```toml
[apps.example]
display-name = "Example"
package-name = "org.example.app"

[apps.example.release]
repository = "OWNER/REPOSITORY"
asset-patterns = ["example-*.apk"]
release-limit = 5
include-prereleases = false
certificates = ["A1B2C3D4..."]
```

The synchronizer converts `.release` entries into release fetch jobs internally.
There is no separate F-Droid source catalog.

`[fdroid]` contains only repository-wide policy:

```toml
[fdroid]
max-repo-asset-size = 104857600
include-built-releases = true
built-release-limit = 10
```

When `include-built-releases` is true, F-Droid also imports patched APKs from this repository's own Releases.

## Add an external release app

Install GitHub CLI, Android `aapt`, and `apksigner`, then authenticate GitHub CLI.
Run:

```sh
./scripts/add-release-app.sh OWNER/REPOSITORY
```

The command inspects the newest matching release assets, reads the Android package name and signer certificate, and appends a pinned `[apps.<name>.release]` entry to `config.toml`.

Use `--pattern` to narrow the accepted assets:

```sh
./scripts/add-release-app.sh OWNER/REPOSITORY \
  --name example-app \
  --pattern '*-arm64-v8a.apk' \
  --pattern '*-universal.apk' \
  --release-limit 5
```

One app entry represents one Android package.
If matching assets contain several package names, narrow the pattern and add them separately.

For a private repository, store a read-only token in an Actions secret and reference only its environment variable name:

```sh
EXTERNAL_RELEASE_TOKEN=github_pat_... \
  ./scripts/add-release-app.sh OWNER/PRIVATE_REPOSITORY \
  --token-env EXTERNAL_RELEASE_TOKEN
```

## Repository signing identity

Create the F-Droid repository identity once:

```sh
./scripts/generate-fdroid-identity.sh
```

The generated files live under the ignored directory:

```text
signing/fdroid/
├── config.yml
├── keystore.p12
├── repository-certificate.pem
├── repository-fingerprint.sha256
└── github-actions-secrets.env
```

Set the `CONFIG_YML` and `KEYSTORE_P12` repository secrets from `github-actions-secrets.env`.
Back up the complete `signing/fdroid/` directory.
Replacing this key creates a different F-Droid repository identity.

## Tool environment

The workflow uses root-level [`pixi.toml`](../pixi.toml).
It pins Pixi 0.76.2 or higher, Python 3.12.13, and the exact `fdroidserver` 2.4.5 source archive with its SHA-256 digest.
The workflow installs only required Android system tools outside Pixi.

## Update behavior

The `Update` workflow checks F-Droid after it publishes patched app release assets.
`Check F-Droid Apps` also checks external release apps every six hours.

The check compares selected immutable GitHub asset IDs with `fdroid/provenance.json`.
If the selected asset set changes, it calls `Publish F-Droid`.

## APK verification

Before an APK enters the repository, the synchronizer verifies the applicable properties:

- APK structure.
- Android package name.
- APK signer certificate.
- SHA-256 hash.
- Native ABI list.
- GitHub `sha256:` asset digest when GitHub provides one.

External apps must match the `certificates` array in their `.release` table.
Patched APKs from this repository are trusted through the package-signing workflow and are not given a second certificate pin in `config.toml`.

The synchronizer rejects conflicting APKs with the same package name, version code, and ABI set.
It replaces the staged repository only after all selected apps pass verification.

`max-repo-asset-size = 104857600` is a repository-wide 100 MiB limit matching GitHub's Git blob limit for the published branch.
Oversized external assets are skipped before download, and the final publish tree is checked again before push.
An individual external app can set a lower `max-asset-size`, but it cannot increase the repository-wide limit.

## Provenance

Each successful publication writes `fdroid/provenance.json` to the `fdroid` branch.
It records the GitHub repository, release tag, immutable asset ID, package and version, APK hash, signer certificate, native ABI list, and final repository filename.

Existing verified APKs can be reused from the `fdroid` branch when their immutable asset IDs still match.
Actions cache is not required for correctness.

## Run synchronization locally

```sh
GH_TOKEN="$(gh auth token)" \
GITHUB_REPOSITORY=OWNER/REPOSITORY \
  ./scripts/sync-fdroid-releases.sh /tmp/fdroid/repo /tmp/fdroid/provenance.json
```

## Client URL

After the first publication, use the URL containing the repository fingerprint:

```text
https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo?fingerprint=SHA256_FINGERPRINT
```

The workflow reads this fingerprint from the signed `index-v1.jar`.
