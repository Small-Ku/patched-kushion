#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/inventory.json" <<'JSON'
[
  {"format":"BUNDLE","arch":"arm64-v8a + armeabi-v7a","minAndroid":"Android 10+","dpi":"213-640dpi","url":"https://example/arm"},
  {"format":"BUNDLE","arch":"universal","minAndroid":"Android 12L+","dpi":"120-640dpi","url":"https://example/modern"},
  {"format":"BUNDLE","arch":"universal","minAndroid":"Android 6.0+","dpi":"160-640dpi","url":"https://example/broad"},
  {"format":"APK","arch":"x86_64","minAndroid":"Android 6.0+","dpi":"nodpi","url":"https://example/x64"},
  {"format":"APK","arch":"arm64-v8a + armeabi-v7a + x86 + x86_64","minAndroid":"Android 6.0+","dpi":"nodpi","url":"https://example/fat"}
]
JSON
python3 "$root/scripts/source_plan.py" --inventory "$tmp/inventory.json" \
  --arches-json '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"},{"arch":"x86_64"}]' --output "$tmp/plan.json" >/dev/null
jq -e '.complete and .artifactCount == 1 and .artifacts[0].url == "https://example/broad"' "$tmp/plan.json" >/dev/null

# Runtime compatibility is not derivability. A fat standalone APK may satisfy
# universal, but it must never be used as four synthetic ABI-specific branches.
jq 'map(select(.url == "https://example/fat"))' "$tmp/inventory.json" > "$tmp/fat-only.json"
python3 "$root/scripts/source_plan.py" --inventory "$tmp/fat-only.json" \
  --arches-json '[{"arch":"universal","sourcePriority":"desired"},{"arch":"arm64-v8a","sourcePriority":"desired"},{"arch":"arm-v7a","sourcePriority":"desired"}]' \
  --output "$tmp/fat-plan.json" >/dev/null
jq -e '.complete and .availableBuildArches == ["universal"] and .missingDesiredArches == ["arm64-v8a","arm-v7a"] and .branchSources.universal == "artifact-1" and (.branchSources["arm64-v8a"] == null)' "$tmp/fat-plan.json" >/dev/null
# Without the broad bundle, the planner computes the whole minimal download set
# before any binary acquisition starts.
jq 'map(select(.url != "https://example/broad" and .url != "https://example/modern"))' "$tmp/inventory.json" > "$tmp/narrow.json"
python3 "$root/scripts/source_plan.py" --inventory "$tmp/narrow.json" \
  --arches-json '[{"arch":"arm64-v8a"},{"arch":"arm-v7a"},{"arch":"x86_64"}]' --output "$tmp/narrow-plan.json" >/dev/null
jq -e '.complete and .artifactCount == 2 and ([.artifacts[].url] | sort) == ["https://example/arm","https://example/x64"]' "$tmp/narrow-plan.json" >/dev/null
# Density constraints are applied during planning rather than after downloading.
python3 "$root/scripts/source_plan.py" --inventory "$tmp/inventory.json" \
  --arches-json '[{"arch":"arm64-v8a"}]' --dpi xxhdpi --output "$tmp/dpi.json" >/dev/null
jq -e '.complete and .artifacts[0].url == "https://example/broad"' "$tmp/dpi.json" >/dev/null

# Optional architectures do not invalidate an otherwise complete broad-bundle
# plan. The planner exposes the missing optional branches explicitly.
python3 "$root/scripts/source_plan.py" --inventory "$tmp/narrow.json" \
  --arches-json '[{"arch":"arm64-v8a","sourcePriority":"required"},{"arch":"arm-v7a","sourcePriority":"required"},{"arch":"x86","optional":true,"sourcePriority":"optional"}]' \
  --output "$tmp/optional-plan.json" >/dev/null
jq -e '.complete and .artifactCount == 1 and .artifacts[0].url == "https://example/arm" and .availableBuildArches == ["arm64-v8a","arm-v7a"] and .missingOptionalArches == ["x86"] and (.branchSources.x86 == null)' "$tmp/optional-plan.json" >/dev/null

# Auto-discovered builds can make every branch optional. We still choose the
# broadest useful bundle rather than declaring that no source plan exists.
python3 "$root/scripts/source_plan.py" --inventory "$tmp/narrow.json" \
  --arches-json '[{"arch":"arm64-v8a","optional":true,"sourcePriority":"desired"},{"arch":"arm-v7a","optional":true,"sourcePriority":"desired"},{"arch":"x86","optional":true,"sourcePriority":"desired"}]' \
  --output "$tmp/all-optional-plan.json" >/dev/null
jq -e '.complete and .artifactCount == 1 and .artifacts[0].url == "https://example/arm" and .availableBuildArches == ["arm64-v8a","arm-v7a"] and .missingDesiredArches == ["x86"] and .missingOptionalArches == []' "$tmp/all-optional-plan.json" >/dev/null

echo 'source download planner test passed'
