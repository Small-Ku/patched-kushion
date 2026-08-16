# APK signing identity

The repository does not contain a shared APK signing key.
Each deployment must create and protect its own signing identity.

## Create the identity

Run this command from the repository root:

```sh
./scripts/generate-package-identity.sh
```

The command creates these files in the ignored `signing/package/` directory:

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

`build.sh` reads `signing/package/package.env` automatically.
The build stops before downloads start if the required identity or password is missing.

```sh
./scripts/generate-package-identity.sh
./build.sh
```

Git ignores the complete `signing/` directory except its README.
Git also ignores common private-keystore file extensions.


## APK finalization

Patched APKs are not published directly from Morphe. The build finishes every APK in this order:

```text
patch and mutate APK
-> embed required patch notice
-> zipalign -P 16 -f 4
-> apksigner sign
-> apksigner verify
-> zipalign -c -P 16 4
```

`zipalign` must run after the last ZIP mutation and before the final package signature.
The 16 KiB page alignment keeps uncompressed native libraries installable when an app declares `extractNativeLibs=false`, while the normal 4-byte alignment still applies to other stored entries.

The builder resolves `zipalign` from the `ZIPALIGN` environment variable, `PATH`, or the newest Android SDK build-tools directory under `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `~/Android/Sdk`.
A missing finalizer, failed APK signature verification, or failed alignment check discards the variant instead of publishing it.

## GitHub Actions

Create these repository secrets from `signing/package/github-actions-secrets.env`:

- `APK_PATCHER_KEYSTORE_B64`
- `APK_APKSIGNER_KEYSTORE_B64`
- `APK_KEYSTORE_PASSWORD`
- `APK_KEY_PASSWORD`
- `APK_KEY_ALIAS`
- `APK_SIGNER_NAME`

The architecture workflow never gives this identity to Source or Stock. Source acquisition/provenance and unsigned Stock merge therefore cannot depend on release-signing secrets.

Morphe requires a signing identity while producing its patch-stage intermediate, so Patch receives the package identity for that operation; the intermediate is never published. Package reloads the identity only for final signing after every branding/NOTICE/alignment mutation. Both jobs remove the temporary keystore files afterwards.

These secrets are separate from the F-Droid repository signing identity.

## Old Git history

Deleting an old key from the current tree does not remove it from old Git objects.
It can also remain in clones, forks, archives, and tags.

Treat an exposed old key as compromised.
A history rewrite can reduce accidental discovery, but it cannot make that key trustworthy again.
