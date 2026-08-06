# Local package-signing identity

Run:

```sh
./scripts/generate-package-identity.sh
```

The generator creates the BKS and PKCS#12 keystores, credentials, public
certificate, fingerprint, and a GitHub Actions secret-value file in this
directory. Everything except this README is ignored by Git.

The generated private keys define the update identity of all patched APKs.
Back up this directory securely and never commit or publish it.
