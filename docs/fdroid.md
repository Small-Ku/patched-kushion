# F-Droid repository setup

The `Publish F-Droid repository` workflow collects APK assets from this
repository's newest GitHub releases, runs `fdroid update`, and pushes the APKs
and signed indexes to the dedicated `fdroid` branch.

The branch is intentionally separate from `main`: generated APKs and indexes do
not inflate source checkouts, and publishing cannot recursively trigger source
workflows.

## One-time signing setup

Install `fdroidserver`, then initialize a local repository:

```sh
mkdir -p fdroid
cd fdroid
fdroid init
```

Edit `config.yml`. At minimum, set a repository name and use the publishing
branch URL:

```yaml
repo_name: patched-kushion
repo_description: Patched Android applications built by patched-kushion
repo_url: https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo
archive_older: 0
```

Keep the generated `keystore.p12` and its passwords safe. Losing or replacing
this repository key changes the F-Droid repository identity.

This F-Droid repository key is independent from the APK package-signing identity
documented in [`package-signing.md`](package-signing.md). Never reuse either
private key for the other purpose.

Encode both files without line wrapping and add them as GitHub Actions
repository secrets:

```sh
base64 -w0 config.yml
base64 -w0 keystore.p12
```

Use these secret names:

- `CONFIG_YML`: base64-encoded `config.yml`
- `KEYSTORE_P12`: base64-encoded `keystore.p12`

Optional repository variables:

- `FDROID_RELEASE_LIMIT`: number of published releases to scan; default `10`
- `FDROIDSERVER_VERSION`: exact PyPI version to pin; latest is used when unset

## Client URL and fingerprint

After the first successful workflow run, read the SHA-256 repository key
fingerprint from the `Generate signed indexes` log. Remove spaces and append it
to the URL:

```text
https://raw.githubusercontent.com/OWNER/REPOSITORY/fdroid/fdroid/repo?fingerprint=SHA256_FINGERPRINT
```

The workflow can be run manually and also runs after a release is published or
edited. A daily scheduled run repairs missed release events.

## Scope

Only `.apk` release assets are indexed. Magisk and KernelSU module ZIP files
remain available through GitHub Releases and are not added to F-Droid.

## Template relationship

This setup follows the signed-index and raw-GitHub hosting model demonstrated by
the supplied GAF-Droid template, but replaces its single-APK-per-application
metadata importer with a release-asset synchronizer. patched-kushion publishes
several apps and architecture variants in each release, so indexing the APKs
directly is both simpler and compatible with the existing build workflow.
