#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/source.log" <<'LOG'
curl: (22) The requested URL returned error: 410
utils.sh [i] Request failed: https://instagram.en.uptodown.com/android/versions
utils.sh [i] Could not inspect 'uptodown' for shared stock
[+] Traversing 'arm64-v8a' source DAG node 'apkpure'
Downloading com.instagram.android version 435.0.0.37.76 arch arm64-v8a...
com.instagram.android@435.0.0.37.76@arm64-v8a downloaded successfully!
[+] Selecting 'arm64-v8a' splits from source-branch-arm64-v8a-apkpure.apk.bundle
stock bundle error: bundle can derive arm-v7a, not arm64-v8a
utils.sh [-] Could not select a coherent split set for 'arm64-v8a' from 'temp/source-branch-arm64-v8a-apkpure.apk.bundle'
utils.sh [i] DAG payload node 'apkpure' failed: version='435.0.0.37.76' arch='arm64-v8a'
[+] Traversing 'arm64-v8a' source DAG node 'apkmirror'
utils.sh [i] Skipping repeated failed 'apkmirror' metadata request during this acquisition
utils.sh [i] Could not inspect 'apkmirror' for 'arm64-v8a' DAG acquisition
[+] Traversing 'arm64-v8a' source DAG node 'aptoide'
utils.sh [i] Aptoide exact-version node rejected: requested '435.0.0.37.76', advertised '442.0.0.32.79'
utils.sh [i] DAG payload node 'aptoide' failed: version='435.0.0.37.76' arch='arm64-v8a'
utils.sh [-] No source DAG path produced a complete acquisition plan for '435.0.0.37.76'
LOG
python3 scripts/build_diagnostics.py source --log "$tmp/source.log" --exit-code 1 --json "$tmp/source.json" >/dev/null
jq -e '
  .stage == "source" and
  .category == "wrong-abi" and
  .failureClass == "source" and
  (.reason | contains("apkpure")) and
  any(.providerAttempts[]; .provider == "apkpure" and .category == "wrong-abi" and .requestedArch == "arm64-v8a" and .actualDerivable == "arm-v7a") and
  any(.providerAttempts[]; .provider == "uptodown" and (.category == "metadata-unavailable" or .category == "metadata-request-failed") and .httpStatus == 410) and
  any(.providerAttempts[]; .provider == "aptoide" and .category == "version-mismatch" and .advertisedVersion == "442.0.0.32.79")
' "$tmp/source.json" >/dev/null

cat > "$tmp/patch-compat.log" <<'LOG'
Piko: Patch failed: fingerprint LoginExperimentFingerprint not found
utils.sh [-] ABORT: Patch preparation produced no reusable artifact.
LOG
python3 scripts/build_diagnostics.py patch --log "$tmp/patch-compat.log" --exit-code 1 --json "$tmp/patch-compat.json" >/dev/null
jq -e '.stage == "patch" and .category == "patch-incompatible" and .failureClass == "compatibility" and (.reason | contains("fingerprint"))' "$tmp/patch-compat.json" >/dev/null

cat > "$tmp/patch-infra.log" <<'LOG'
java.net.ConnectException: ETIMEDOUT while fetching helper metadata
LOG
python3 scripts/build_diagnostics.py patch --log "$tmp/patch-infra.log" --exit-code 1 --json "$tmp/patch-infra.json" >/dev/null
jq -e '.category == "network-failed" and .failureClass == "infrastructure"' "$tmp/patch-infra.json" >/dev/null

# Missing logs still yield a deterministic generic classification.
python3 scripts/build_diagnostics.py patch --log "$tmp/missing.log" --exit-code 7 --json "$tmp/missing.json" >/dev/null
jq -e '.category == "patch-failed" and .reason == "patch stage exited 7"' "$tmp/missing.json" >/dev/null

echo '[PASS] build-stage diagnostics classify provider, compatibility, and infrastructure failures'
