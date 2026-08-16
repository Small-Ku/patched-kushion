#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck disable=SC1091
source "$root/utils.sh"
# shellcheck disable=SC1091
source "$root/tests/testlib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TEMP_DIR="$tmp/temp"; BIN_DIR="$tmp/bin"; mkdir -p "$TEMP_DIR" "$BIN_DIR"

[ "${DL_SRCS[*]}" = "direct aptoide apkpure uptodown archive apkmirror" ]
[ "${SHARED_DL_SRCS[*]}" = "direct apkmirror apkpure archive uptodown" ]


# Third-party transports are never trust-on-first-use. A package without an
# explicit upstream signer pin is rejected before apksigner is even invoked.
__TOML__='{"upstream-signatures":{}}'
APKSIGNER="$tmp/should-not-run.jar"
expect_failure_matching \
  'reject unpinned stock from a third-party source' 2 \
  'Refusing unpinned stock' \
  check_sig "$tmp/fixture.apk" com.example.app aptoide
check_sig "$tmp/fixture.apk" com.example.app direct >/dev/null
[ "$(source_trust_class apkpure)" = third-party-store ]
[ "$(source_trust_class apkmirror)" = third-party-mirror ]
[ "$(source_provenance_domain apkpure com.example.app)" = apkpure.com ]
[ "$(source_provenance_domain apkmirror https://www.apkmirror.com/apk/example/app/)" = apkmirror.com ]
[ "$(source_provenance_domain mirror_alias https://download.apkpure.com/app.apk)" = apkpure.com ]
sources_share_provenance apkpure com.example.app mirror_alias https://download.apkpure.com/app.apk

# Aptoide is an API-backed exact-version fallback. A stale/current mismatch must
# fall through rather than silently substituting another version.
req() {
  local url=$1 output=$2
  case "$url" in
    https://ws2.aptoide.com/api/7/app/getMeta/package_name=com.example.app)
      cat <<'JSON'
{"data":{"package":"com.example.app","file":{"vername":"2.3.4","path":"https://cdn.example.invalid/app.apk"}}}
JSON
      ;;
    https://cdn.example.invalid/app.apk)
      [ "$output" != - ] || return 1
      cp "$tmp/fixture.apk" "$output"
      ;;
    *) echo "unexpected request: $url" >&2; return 1 ;;
  esac
}
printf 'fixture-apk' > "$tmp/fixture.apk"
get_aptoide_resp com.example.app
[ "$(get_aptoide_pkg_name)" = com.example.app ]
[ "$(get_aptoide_vers)" = 2.3.4 ]
dl_aptoide com.example.app 2.3.4 "$tmp/aptoide.apk" arm64-v8a ''
cmp "$tmp/fixture.apk" "$tmp/aptoide.apk"
expect_failure_status \
  'reject an Aptoide artifact whose current version does not match the requested version' 1 \
  dl_aptoide com.example.app 2.3.3 "$tmp/stale.apk" arm64-v8a ''
[ ! -e "$tmp/stale.apk" ]

# Model an apkeep binary. Single-ABI requests return an APK; multi-ABI requests
# return a split XAPK so shared-source planning can reuse one download.
python3 - "$tmp/fixture-real.apk" "$tmp/fixture.xapk" <<'PY'
import io, sys, zipfile

def apk(libs=()):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr('AndroidManifest.xml', b'manifest')
        for abi in libs:
            z.writestr(f'lib/{abi}/libx.so', b'x')
    return out.getvalue()

with open(sys.argv[1], 'wb') as fh:
    fh.write(apk(('arm64-v8a',)))
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    z.writestr('base.apk', apk())
    z.writestr('split_config.arm64_v8a.apk', apk(('arm64-v8a',)))
    z.writestr('split_config.armeabi_v7a.apk', apk(('armeabi-v7a',)))
    z.writestr('split_config.en.apk', apk())
PY
cat > "$tmp/fake-apkeep" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
out=${@: -1}
mkdir -p "$out"
arch=''
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = -o ]; then arch=${args[$((i+1))]#arch=}; fi
done
if [[ "$arch" == *';'* ]]; then
  cp "$FIXTURE_BUNDLE" "$out/result.xapk"
else
  cp "$FIXTURE_APK" "$out/result.apk"
fi
FAKE
chmod +x "$tmp/fake-apkeep"
export FIXTURE_APK="$tmp/fixture-real.apk" FIXTURE_BUNDLE="$tmp/fixture.xapk"
APKEEP_BIN="$tmp/fake-apkeep"
unset APKEEP || :

get_apkpure_resp com.example.app
[ "$(get_apkpure_pkg_name)" = com.example.app ]
dl_apkpure com.example.app 2.3.4 "$tmp/apkpure.apk" arm64-v8a ''
cmp "$tmp/fixture-real.apk" "$tmp/apkpure.apk"

shared="$tmp/shared.xapk"
dl_apkpure_shared com.example.app 2.3.4 "$shared" '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"}]' ''
[ -s "$shared" ]
jq -e '.source == "apkpure" and (.requestedAbis | index("arm64-v8a") != null) and (.requestedAbis | index("armeabi-v7a") != null)' "$shared.source.json" >/dev/null
python3 "$root/scripts/stock_bundle.py" inspect --bundle "$shared" >/dev/null

# The pinned helper bootstrap trusts GitHub release metadata only when it carries
# a matching sha256 digest for the exact platform asset.
unset APKEEP_BIN APKEEP
helper="$tmp/helper"
printf '#!/usr/bin/env bash\nexit 0\n' > "$helper"; chmod +x "$helper"
helper_digest=$(sha256sum "$helper" | awk '{print $1}')
gh_req() {
  cat <<JSON
{"assets":[{"name":"apkeep-x86_64-unknown-linux-gnu","browser_download_url":"https://example.invalid/apkeep","digest":"sha256:${helper_digest}"}]}
JSON
}
gh_dl() { cp "$helper" "$1"; }
ensure_apkeep
[ -x "$APKEEP" ]
[ "$(sha256sum "$APKEEP" | awk '{print $1}')" = "$helper_digest" ]

echo 'stock source fallback test passed'
