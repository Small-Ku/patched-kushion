# F-Droid repository setup

The `Publish F-Droid repository` workflow builds a signed binary repository on
the dedicated `fdroid` branch. APKs may come from patched-kushion releases or
from other GitHub repositories listed in [`fdroid/sources.toml`](../fdroid/sources.toml).

Generated APKs, indexes, and `provenance.json` stay off `main`. Magisk and
KernelSU ZIPs are not imported.

## One-time repository signing setup

Install `fdroidserver`, then initialize a local repository:

```sh
mkdir -p fdroid-signing
cd fdroid-signing
fdroid init
```

Edit `config.yml`. At minimum, set the repository name and publishing URL:

```yaml
repo_name: patched-kushion
repo_description: Patched and externally sourced Android applications
repo_url: https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo
archive_older: 0
```

Keep the generated `keystore.p12` and its passwords private. This repository
key signs the F-Droid indexes; it is independent from every APK signing key and
from patched-kushion's package-signing identity.

Encode both files without line wrapping and create these GitHub Actions secrets:

```sh
base64 -w0 config.yml
base64 -w0 keystore.p12
```

- `CONFIG_YML`: base64-encoded `config.yml`
- `KEYSTORE_P12`: base64-encoded `keystore.p12`

Optional repository variable:

- `FDROIDSERVER_VERSION`: exact `fdroidserver` PyPI version to install

## Add an external GitHub Release source

Install the GitHub CLI, Android `aapt`, and `apksigner`, authenticate `gh`, then
run:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY
```

The command finds the newest release containing a matching APK, downloads it,
verifies its APK signature, reads its package name, and appends both the package
identity and certificate SHA-256 pin to `fdroid/sources.toml`.

Use asset patterns when a release also contains unwanted APK variants:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY \
  --name example-app \
  --pattern 'example-universal-*.apk' \
  --release-limit 5
```

Repeat `--pattern` to accept several asset names:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY \
  --pattern '*-arm64-v8a.apk' \
  --pattern '*-armeabi-v7a.apk'
```

Review and commit the resulting configuration. The same GitHub repository may
appear in several source entries when unique names and non-overlapping asset
patterns are needed. A generated entry resembles:

```toml
[[source]]
name = "example-app"
repository = "OWNER/REPOSITORY"
asset-patterns = ["example-universal-*.apk"]
release-limit = 5
include-prereleases = false
[source.package-certificates]
"org.example.app" = ["A1B2C3D4E5F6A7B8..."]
```

Do not manually set `allow-unpinned = true` for an external repository. The
synchronizer permits that exception only for `repository = "@self"`.

## Private external repositories

Create a fine-grained token with read-only access to the required repositories,
store it as the `EXTERNAL_RELEASE_TOKEN` Actions secret, and add the source with:

```sh
EXTERNAL_RELEASE_TOKEN=github_pat_... \
  ./scripts/add-fdroid-source.sh OWNER/PRIVATE_REPOSITORY \
  --token-env EXTERNAL_RELEASE_TOKEN
```

The token name is written to the source configuration, never the token value.
During scheduled publishing the workflow exposes only the corresponding secret.
Public repositories normally need no additional token beyond `GH_TOKEN`.

## Automatic updates

The F-Droid workflow runs:

- immediately when this repository publishes or edits a release;
- manually through `workflow_dispatch`;
- every six hours to discover releases from external sources.

For every configured source, the synchronizer retains the newest eligible
`release-limit` releases, downloads only matching `.apk` assets, and verifies:

- the APK is structurally valid and correctly signed;
- its package name and signer certificate match an exact configured identity;
- a GitHub-provided `sha256:` asset digest, when present;
- conflicting APKs do not claim the same package, versionCode, and native ABI.

Only after all sources pass validation does it replace the staged APK set. A
failed or compromised upstream therefore cannot partially overwrite the current
repository.

Each successful run writes `fdroid/provenance.json` on the publishing branch.
It records the upstream repository, release tag, asset name and URL, package
identity, version, APK SHA-256, certificate fingerprint, ABI list, and final
repository filename.

## Local synchronization

To exercise the same importer locally:

```sh
GH_TOKEN="$(gh auth token)" \
GITHUB_REPOSITORY=OWNER/REPOSITORY \
  ./scripts/sync-fdroid-releases.sh /tmp/fdroid/repo /tmp/fdroid/provenance.json
```

This command downloads binaries. The resulting local `fdroid/repo/` and
`fdroid/provenance.json` are ignored by Git.

## Client URL and fingerprint

After the first successful workflow run, append the repository key SHA-256
fingerprint to the raw branch URL:

```text
https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo?fingerprint=SHA256_FINGERPRINT
```

## Signing model

External APKs remain byte-for-byte upstream-signed. patched-kushion does not
re-sign them. The F-Droid repository key signs only the repository indexes, and
the per-source certificate pins ensure that a future upstream release still
uses the expected APK identity.
