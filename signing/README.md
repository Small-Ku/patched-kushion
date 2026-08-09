# Local signing identities

All locally managed signing material lives under this directory. Git tracks only this README.

```text
signing/
├── package/   # patched non-root APK signing identity
└── fdroid/    # F-Droid repository signing identity
```

Create the APK identity with:

```sh
./scripts/generate-package-identity.sh
```

Create the F-Droid repository identity with:

```sh
./scripts/generate-fdroid-identity.sh
```

Back up both subdirectories securely after you publish with them. Never commit or publish their private key material.
