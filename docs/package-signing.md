# APK package-signing identity

The repository does not contain a shared APK signing key. Every deployment must
create and protect its own package-signing identity.

## Generate an identity

From the repository root:

```sh
./scripts/generate-package-identity.sh
```

This creates, under the ignored `signing/` directory:

- `package.keystore`: BKS keystore used by the patching CLIs
- `package.p12`: PKCS#12 copy of the same private key used by `apksigner`
- `package.env`: local build configuration and passwords
- `package-certificate.pem`: public certificate
- `package-certificate.sha256`: certificate fingerprint
- `github-actions-secrets.env`: values to copy into GitHub Actions secrets

The two keystores contain the same key pair. They exist in different formats
only because the patching and split-APK signing paths use different keystore
implementations.

Running the command again refuses to overwrite an identity. Use `--force` only
when intentionally rotating to a new identity:

```sh
./scripts/generate-package-identity.sh --force
```

A newly generated identity cannot update APKs signed with the previous identity.
Because the old repository key files were public, they must remain retired.

## Local builds

`build.sh` automatically reads `signing/package.env`. It fails before downloading
or patching anything when the identity or credentials are missing.

```sh
./scripts/generate-package-identity.sh
./build.sh
```

The whole `signing/` directory is ignored except for its README. Generic private
keystore extensions are also ignored as a second line of defence.

## GitHub Actions

Create these repository secrets using the values in
`signing/github-actions-secrets.env`:

- `APK_PATCHER_KEYSTORE_B64`
- `APK_APKSIGNER_KEYSTORE_B64`
- `APK_KEYSTORE_PASSWORD`
- `APK_KEY_PASSWORD`
- `APK_KEY_ALIAS`
- `APK_SIGNER_NAME`

The build workflow reconstructs both keystores only on its ephemeral runner,
uses them to sign the release, and removes them immediately after the build
step. These secrets are separate from the F-Droid repository signing key.

## Existing Git history

This commit removes `ks.keystore` and `ks-p12.keystore` from the current tree,
but an ordinary deletion commit cannot erase them from earlier Git objects,
clones, forks, archives, or tags. Treat the old key as permanently compromised.
A later history rewrite may reduce accidental discovery, but it cannot make the
old identity trustworthy again.
