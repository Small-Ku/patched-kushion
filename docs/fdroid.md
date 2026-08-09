# F-Droid repository setup

The `Publish F-Droid repository` workflow builds a signed binary repository on
the dedicated `fdroid` branch. APKs may come from patched-kushion releases or
from other GitHub repositories listed in [`fdroid/sources.toml`](../fdroid/sources.toml).

Generated APKs, indexes, and `provenance.json` stay off `main`. Magisk and
KernelSU ZIPs are not imported. Stable patched-kushion package identities receive
F-Droid descriptions generated from `package-identities.toml` and `config.toml`;
external mirrored APK metadata is left to F-Droid's normal APK inspection.

## One-time repository signing setup

Generate the repository signing identity from a checkout of this repository:

```sh
./scripts/generate-fdroid-identity.sh
```

The helper infers `OWNER/REPOSITORY` from `GITHUB_REPOSITORY` or the GitHub
`origin` remote. If the checkout does not have a GitHub remote, pass it
explicitly:

```sh
./scripts/generate-fdroid-identity.sh --repository OWNER/REPOSITORY
```

Only a JDK with `keytool` is required; `fdroid init` and an Android SDK are not
needed just to create the repository identity. The generated, Git-ignored
`fdroid-signing/` directory contains:

```text
fdroid-signing/
├── config.yml
├── keystore.p12
├── repository-certificate.pem
├── repository-fingerprint.sha256
└── github-actions-secrets.env
```

`config.yml` and `keystore.p12` contain private signing credentials. The
certificate and fingerprint are public trust material. The generated
`github-actions-secrets.env` contains exactly the two values required by the
publishing workflow:

- `CONFIG_YML`: base64-encoded `config.yml`
- `KEYSTORE_P12`: base64-encoded `keystore.p12`

Copy those two values to GitHub **Settings → Secrets and variables → Actions →
Repository secrets**, then run **Publish F-Droid repository**. If GitHub CLI is
already authenticated, they can also be uploaded from the generated file:

```sh
while IFS='=' read -r name value; do
  printf '%s' "$value" | gh secret set "$name" --body -
done < fdroid-signing/github-actions-secrets.env
```

The repository key signs the F-Droid indexes. It is independent from every APK
signing key and from patched-kushion's package-signing identity. Back up the
entire `fdroid-signing/` directory securely: losing or rotating this key changes
the repository identity seen by existing F-Droid clients.

Use `--force` only when intentionally rotating the repository identity. The
helper prints the canonical raw-GitHub client URL with the generated SHA-256
fingerprint; the `fdroid` publishing branch independently extracts that
fingerprint from the signed `index-v1.jar` on every publication.

The workflow uses the commit-pinned `astral-sh/setup-uv` action, the uv version
pinned in [`fdroid/uv.toml`](../fdroid/uv.toml), and managed Python 3.12.13.
[`fdroid/requirements.txt`](../fdroid/requirements.txt) pins the exact
`fdroidserver` source archive URL and SHA-256 digest rather than trusting only a
version label. `setup-uv` caches both uv package downloads and the managed Python
installation between workflow runs.

The requirements flow intentionally remains separate from a uv project lock:
`fdroidserver` is distributed as a source archive and its complete transitive
wheel set is not vendored here. Do not add a hand-written `uv.lock`; generate
one only from a reviewed, complete dependency resolution.

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

F-Droid publishing is event-chained rather than time-chained:

- the update pipeline calls the reusable F-Droid workflow immediately after a successful build;
- the F-Droid workflow can still be invoked manually for recovery;
- a lightweight source watcher runs every six hours and calls the F-Droid workflow only when the selected immutable asset IDs of external sources change.

The watcher fetches only release metadata plus the small published `provenance.json`;
it does not install F-Droid tooling or download APKs unless a change is detected.

For every configured source, the synchronizer retains the newest eligible
`release-limit` releases. It reuses an APK already present on the `fdroid`
branch when the immutable GitHub asset ID is still present in provenance and
the local APK passes fresh hash, package, ABI, and signer verification. New,
missing, or damaged APKs are downloaded again. It then verifies:

- the APK is structurally valid and correctly signed;
- its package name and signer certificate match an exact configured identity;
- a GitHub-provided `sha256:` asset digest, when present;
- conflicting APKs do not claim the same package, versionCode, and native ABI.

Only after all sources pass validation does it replace the staged APK set. A
failed or compromised upstream therefore cannot partially overwrite the current
repository.

Each successful run writes `fdroid/provenance.json` on the publishing branch.
It records the immutable GitHub asset ID, upstream repository, release tag,
asset name and URL, package identity, version, APK SHA-256, certificate
fingerprint, ABI list, and final repository filename. The branch remains the
auditable source of reusable APKs; Actions cache is only an optional transport
optimization and is never required for correctness.

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
