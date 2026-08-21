#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck disable=SC1091
source ./utils.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
REQ_LOG="$tmp/requests"
: >"$REQ_LOG"
req() {
    printf '%s\n' "$1" >>"$REQ_LOG"
    case "$1" in
        https://example.invalid/app/versions)
            printf '<html><body><span class="version">1.2.3</span></body></html>'
            ;;
        https://example.invalid/app/download)
            printf '<table><tr class="full"><td></td><td></td><td>com.example.app</td></tr></table>'
            ;;
        *) return 1 ;;
    esac
}
HTMLQ=cat

get_uptodown_resp https://example.invalid/app
[ "$(wc -l <"$REQ_LOG")" -eq 1 ]
[ "$(sed -n '1p' "$REQ_LOG")" = https://example.invalid/app/versions ]
[ -z "${__UPTODOWN_RESP_PKG__:-}" ]

# A metadata-only DAG probe must not make /download availability part of
# provider availability. Package-name lookup may fetch it lazily when needed.
req() {
    printf '%s\n' "$1" >>"$REQ_LOG"
    case "$1" in
        https://example.invalid/app/versions)
            printf '<html><body><span class="version">1.2.3</span></body></html>'
            ;;
        https://example.invalid/app/download)
            return 1
            ;;
        *) return 1 ;;
    esac
}
: >"$REQ_LOG"
get_uptodown_resp https://example.invalid/app
[ "$(wc -l <"$REQ_LOG")" -eq 1 ]
if get_uptodown_pkg_name >/dev/null 2>&1; then
    echo 'expected lazy package-name fetch to fail' >&2
    exit 1
fi
[ "$(wc -l <"$REQ_LOG")" -eq 2 ]
[ "$(sed -n '2p' "$REQ_LOG")" = https://example.invalid/app/download ]

printf 'uptodown metadata tests passed\n'
