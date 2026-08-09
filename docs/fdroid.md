# F-Droid repository

The `Publish F-Droid` workflow publishes a signed F-Droid repository on the `fdroid` branch.
The repository can contain patched-kushion APKs and selected external GitHub Release APKs.

The `main` branch does not store generated APKs, indexes, or provenance data.
F-Droid does not publish Magisk or KernelSU ZIP files.

## Create the repository identity

Run this command once for a new deployment:

```sh
./scripts/generate-fdroid-identity.sh
```

The script reads `OWNER/REPOSITORY` from `GITHUB_REPOSITORY` or the GitHub `origin` remote.
If it cannot read the repository name, give it explicitly:

```sh
./scripts/generate-fdroid-identity.sh --repository OWNER/REPOSITORY
```

The script needs a JDK with `keytool`.
It does not need `fdroid init` or an Android SDK.

The script creates this ignored directory:

```text
fdroid-signing/
├── config.yml
├── keystore.p12
├── repository-certificate.pem
├── repository-fingerprint.sha256
└── github-actions-secrets.env
```

`config.yml` and `keystore.p12` contain private signing data.
The certificate and fingerprint are public.

Set these GitHub Actions repository secrets from `github-actions-secrets.env`:

- `CONFIG_YML`
- `KEYSTORE_P12`

You can set them with GitHub CLI:

```sh
while IFS='=' read -r name value; do
  printf '%s' "$value" | gh secret set "$name" --body -
done < fdroid-signing/github-actions-secrets.env
```

Back up the complete `fdroid-signing/` directory.
If you replace this key, existing clients see a different repository identity.

Use `--force` only when you intend to replace the repository identity.

## Tool versions

The workflow uses a commit-pinned `astral-sh/setup-uv` action.
[`fdroid/uv.toml`](../fdroid/uv.toml) pins the uv version.
The workflow uses managed Python 3.12.13.

[`fdroid/requirements.txt`](../fdroid/requirements.txt) pins the `fdroidserver` source archive and SHA-256 hash.
The project does not use a hand-written `uv.lock` for this tool-only environment.

## Add an external source

Install GitHub CLI, Android `aapt`, and `apksigner`.
Authenticate GitHub CLI.
Then run:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY
```

The command checks the newest matching release APK.
It reads the package name and signing certificate.
It then adds a pinned source entry to `fdroid/sources.toml`.

Use `--pattern` when a release contains APKs that you do not want:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY \
  --name example-app \
  --pattern 'example-universal-*.apk' \
  --release-limit 5
```

Repeat `--pattern` to accept more than one file pattern:

```sh
./scripts/add-fdroid-source.sh OWNER/REPOSITORY \
  --pattern '*-arm64-v8a.apk' \
  --pattern '*-armeabi-v7a.apk'
```

Review the generated configuration before you commit it.

Example:

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

Do not set `allow-unpinned = true` for an external repository.
The synchronizer permits this setting only for `repository = "@self"`.

## Private external sources

Create a fine-grained GitHub token with read-only access to the required repository.
Save the token as the `EXTERNAL_RELEASE_TOKEN` Actions secret.

Add the source with:

```sh
EXTERNAL_RELEASE_TOKEN=github_pat_... \
  ./scripts/add-fdroid-source.sh OWNER/PRIVATE_REPOSITORY \
  --token-env EXTERNAL_RELEASE_TOKEN
```

The configuration stores only the environment-variable name.
It does not store the token value.

Public repositories normally need only `GH_TOKEN`.

## Update behavior

The `Update` workflow checks F-Droid after it publishes app release assets.
The `Check F-Droid Sources` workflow also runs every six hours.

Both workflows use the same source-state check.
The check compares configured release assets with `fdroid/provenance.json`.

If the state is current, F-Droid publication does not run.
If the state is not current, the workflow calls `Publish F-Droid`.

The six-hour check reads release metadata and the published provenance file first.
It downloads APKs only when publication is required.

## APK synchronization

For each source, the synchronizer keeps the newest eligible `release-limit` releases.
It can reuse an APK from the `fdroid` branch when the recorded GitHub asset ID still exists.

Before reuse, it verifies the local APK again.
It checks these properties:

- APK structure.
- APK signature.
- Package name.
- Signer certificate.
- SHA-256 hash.
- Native ABI list.
- GitHub `sha256:` asset digest when GitHub provides one.

The synchronizer reads native ABIs from `lib/<abi>/*.so` entries in the APK.
If the APK has no recognized native-library path, it falls back to `aapt` data.

The synchronizer rejects conflicting APKs with the same package, version code, and ABI set.
It replaces the staged repository only after all selected sources pass verification.

Sources may also set `max-asset-size` to a byte limit. The self-built source uses `104857600` (100 MiB), matching the GitHub Git blob limit used by the `fdroid` branch. Matching release assets above that limit are ignored before download. They remain available from GitHub Releases, and if a future universal APK falls below the limit it is admitted automatically without a filename-specific exception.

## Provenance

Each successful publication writes `fdroid/provenance.json` to the `fdroid` branch.

The file records:

- GitHub repository.
- Release tag.
- Immutable asset ID.
- Asset name and URL.
- Package name and version.
- APK SHA-256 hash.
- Signer certificate fingerprint.
- Native ABI list.
- Final repository file name.

The `fdroid` branch is the durable source for reusable APKs.
Actions cache is not required for correctness.

## Run synchronization locally

Use this command:

```sh
GH_TOKEN="$(gh auth token)" \
GITHUB_REPOSITORY=OWNER/REPOSITORY \
  ./scripts/sync-fdroid-releases.sh /tmp/fdroid/repo /tmp/fdroid/provenance.json
```

This command downloads APK files.
Git ignores the local output paths.

## Client URL

After the first successful publication, use the URL that contains the repository fingerprint:

```text
https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo?fingerprint=SHA256_FINGERPRINT
```

The workflow reads the fingerprint from the signed `index-v1.jar` after each publication.

## Signing model

External APKs keep their upstream signatures.
patched-kushion does not re-sign them.

The F-Droid repository key signs only the repository indexes.
Per-source certificate pins verify the expected APK signer before publication.
