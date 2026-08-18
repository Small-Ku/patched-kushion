#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
build=$(cat .github/workflows/build.yml)
arch=$(cat .github/workflows/build-arch.yml)
pipeline=$(cat .github/workflows/pipeline.yml)

source_key=$(grep 'key: patched-kushion-source-v2-' .github/workflows/build.yml | head -1)
[[ "$source_key" == *'matrix.candidate.sourceCacheKey'* ]]
[[ "$source_key" != *'patchAssetHash'* ]]
stock_key=$(grep 'key: patched-kushion-stock-v2-' .github/workflows/build-arch.yml | head -1)
[[ "$stock_key" == *'inputs.source_cache_key'* ]]
[[ "$stock_key" == *'inputs.stock_policy_hash'* ]]
patch_key=$(grep 'key: patched-kushion-patch-v2-' .github/workflows/build-arch.yml | head -1)
[[ "$patch_key" == *'steps.variant.outputs.input_id'* ]]
[[ "$patch_key" == *'steps.patch_identity.outputs.stock_sha'* ]]
[[ "$patch_key" == *'steps.patch_identity.outputs.cert_sha'* ]]
[[ "$patch_key" != *'release_tag'* ]]
[[ "$arch" == *"inputs.force_build != true"* ]]
[[ "$pipeline" == *"force_build:"* ]]
[[ "$build" == *"cache_handoff.py source"* ]]
[[ "$arch" == *"cache_handoff.py stock"* ]]
[[ "$arch" == *"cache_handoff.py patch"* ]]

echo 'workflow cross-run cache policy test passed'
