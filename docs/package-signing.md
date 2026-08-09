# APK signing identity

The repository does not contain a shared APK signing key.
Each deployment must create and protect its own signing identity.

## Create the identity

Run this command from the repository root:

```sh
./scripts/generate-package-identity.sh
```

The command creates these files in the ignored `signing/` directory:

- `package.keystore`: BKS keystore for the patcher.
- `package.p12`: PKCS#12 keystore for `apksigner`.
- `package.env`: Local signing settings and passwords.
- `package-certificate.pem`: Public certificate.
- `package-certificate.sha256`: Certificate fingerprint.
- `github-actions-secrets.env`: Values for GitHub Actions secrets.

The BKS and PKCS#12 files contain the same key pair.
The tools require different keystore formats.

The generator does not overwrite an existing identity.
Use `--force` only when you intend to create a new identity:

```sh
./scripts/generate-package-identity.sh --force
```

A new identity cannot update APKs that the old identity signed.
Do not use a retired public key again.

## Local builds

`build.sh` reads `signing/package.env` automatically.
The build stops before downloads start if the required identity or password is missing.

```sh
./scripts/generate-package-identity.sh
./build.sh
```

Git ignores the complete `signing/` directory except its README.
Git also ignores common private-keystore file extensions.

## GitHub Actions

Create these repository secrets from `signing/github-actions-secrets.env`:

- `APK_PATCHER_KEYSTORE_B64`
- `APK_APKSIGNER_KEYSTORE_B64`
- `APK_KEYSTORE_PASSWORD`
- `APK_KEY_PASSWORD`
- `APK_KEY_ALIAS`
- `APK_SIGNER_NAME`

The `Build Variant` workflow creates the keystore files only on its runner.
It removes the files after the build step.

These secrets are separate from the F-Droid repository signing identity.

## Old Git history

Deleting an old key from the current tree does not remove it from old Git objects.
It can also remain in clones, forks, archives, and tags.

Treat an exposed old key as compromised.
A history rewrite can reduce accidental discovery, but it cannot make that key trustworthy again.
