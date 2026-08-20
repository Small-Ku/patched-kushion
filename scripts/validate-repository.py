#!/usr/bin/env python3
import pathlib
import re
import tomllib

config = tomllib.loads(pathlib.Path("config.toml").read_text())
pixi = tomllib.loads(pathlib.Path("pixi.toml").read_text())
fdroid_workflow = pathlib.Path(".github/workflows/fdroid.yml").read_text()
pipeline_workflow = pathlib.Path(".github/workflows/pipeline.yml").read_text()
build_workflow = pathlib.Path(".github/workflows/build.yml").read_text()
build_arch_workflow = pathlib.Path(".github/workflows/build-arch.yml").read_text()
watch_workflow = pathlib.Path(".github/workflows/fdroid-watch.yml").read_text()

assert config["config-version"] == 1
assert set(config) == {"config-version", "build", "stock-security", "apps", "upstream-signatures", "fdroid"}
build = config["build"]
assert build["patches-source"] == "MorpheApp/morphe-patches"
assert build["cli-source"] == "MorpheApp/morphe-desktop"
assert build["patch-brand"] == "Morphe"
assert build["publish-consistency"] == "target"
assert build["forward-compatibility-probes"] == 2
assert build["enable-aptoide"] is True
assert build["enable-apkpure"] is True
assert "rv-brand" not in build
stock_security = config["stock-security"]
assert stock_security["cross-source-verification"] == "opportunistic"
assert all(len(value) == 64 for value in stock_security["deny-sha256"])
assert "38.190.225.166" in stock_security["deny-indicators"]

apps = config["apps"]
assert apps
for name, app in apps.items():
    assert ("build" in app) != ("release" in app), name

assert apps["KouTube"]["package-name"] == "de.kwoo.shion.youtube"
assert apps["KouTube"]["upstream-package"] == "com.google.android.youtube"
assert apps["KouMusik"]["package-name"] == "de.kwoo.shion.music"
assert apps["KouMusik"]["build"]["arches"] == ["arm64-v8a"]
assert "KouX" not in apps
assert "KouThreads" not in apps
assert "KouFacebook" not in apps
assert apps["KouPhotos"]["package-name"] == "de.kwoo.shion.photos"
photos = apps["KouPhotos"]["build"]
assert photos["patches-source"] == "RookieEnough/De-Vanced"
assert photos["build-mode"] == "both"
assert "arch" not in photos and "arches" not in photos

sing_box = apps["sing-box"]
assert sing_box["package-name"] == "io.nekohasekai.sfa"
sing_release = sing_box["release"]
assert sing_release["repository"] == "SagerNet/sing-box"
assert sing_release["asset-patterns"] == [
    "SFA-*-arm64-v8a.apk",
    "SFA-*-armeabi-v7a.apk",
    "SFA-*-x86.apk",
    "SFA-*-x86_64.apk",
    "SFA-*-universal.apk",
]
assert sing_release["asset-exclude-patterns"] == ["*-legacy-*"]
assert sing_release["asset-native-codes"] == {
    "SFA-*-arm64-v8a.apk": ["arm64-v8a"],
    "SFA-*-armeabi-v7a.apk": ["armeabi-v7a"],
    "SFA-*-x86.apk": ["x86"],
    "SFA-*-x86_64.apk": ["x86_64"],
    "SFA-*-universal.apk": ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"],
}
assert sing_release["include-prereleases"] is True
assert sing_release["certificates"] == [
    "32250A4B5F3A6733DF57A3B9EC16C38D2C7FC5F2F693A9636F8F7B3BE3549641"
]
microg_re = apps["MicroG-RE"]
assert microg_re["package-name"] == "app.revanced.android.gms"
assert microg_re["release"]["repository"] == "MorpheApp/MicroG-RE"
assert microg_re["release"]["asset-patterns"] == ["microg-*.apk"]
assert microg_re["release"]["certificates"] == [
    "0B6C9515AFB195FAC59601696BA0A7907A0B217CCF720B43148427CCF64343E7"
]

fdroid = config["fdroid"]
assert fdroid["max-repo-asset-size"] == 104857600
assert fdroid["include-built-releases"] is True
assert fdroid["built-release-limit"] == 10

assert pixi["workspace"]["name"] == "patched-kushion"
assert pixi["workspace"]["channels"] == ["https://prefix.dev/github-releases", "conda-forge"]
assert pixi["workspace"]["platforms"] == ["linux-64", "win-64"]
assert pixi["workspace"]["requires-pixi"] == ">=0.76.2"
assert pixi["dependencies"]["python"] == "*"
assert pixi["dependencies"]["graalvm"] == ">=25.2.4,<26"
assert pixi["pypi-dependencies"]["fdroidserver"] == ">=2.4.5, <3"
assert pixi["activation"]["env"]["ANDROID_BUILD_TOOLS_VERSION"] == "36.0.0"
assert pixi["activation"]["env"]["ANDROID_SDKMANAGER_TIMEOUT_SECONDS"] == "240"
assert pixi["tasks"]["toolchain-info"] == "scripts/toolchain-info.sh"
assert pixi["tasks"]["android-tools"] == "scripts/ensure-android-build-tools.sh"
assert pixi["tasks"]["ci-validate"] == "scripts/validate-repository.sh"

lock_text = pathlib.Path("pixi.lock").read_text()
linux_graal = re.search(r"linux-64/graalvm-(25\.[0-9.]+)-[^/ ]+\.conda", lock_text)
win_graal = re.search(r"win-64/graalvm-(25\.[0-9.]+)-[^/ ]+\.conda", lock_text)
fdroid_lock = re.search(r"fdroidserver-(\d+\.\d+\.\d+)\.tar\.gz", lock_text)
assert linux_graal and win_graal
assert linux_graal.group(1) == win_graal.group(1)
assert tuple(map(int, linux_graal.group(1).split("."))) >= (25, 2, 4)
assert fdroid_lock and tuple(map(int, fdroid_lock.group(1).split("."))) >= (2, 4, 5)

toolchain_action = pathlib.Path(".github/actions/setup-toolchain/action.yml").read_text()
assert "prefix-dev/setup-pixi@f00437f565399d418b0acc85936d12c1fb668347" in toolchain_action
assert "pixi-version: v0.76.2" in toolchain_action
assert "activate-environment: true" in toolchain_action
assert "cache: true" in toolchain_action
assert "cache-key: patched-kushion-pixi-" in toolchain_action
assert "locked: true" in toolchain_action
assert "pixi run toolchain-info" in toolchain_action
assert "pixi run android-tools" in toolchain_action
assert "graalvm" in pathlib.Path("scripts/toolchain-info.sh").read_text().lower()

assert "actions/setup-python" not in fdroid_workflow
assert "astral-sh/setup-uv" not in fdroid_workflow
assert "uv pip" not in fdroid_workflow
assert "uses: ./.github/actions/setup-toolchain" in fdroid_workflow
assert 'android-tools: "true"' in fdroid_workflow
assert "manifest-path:" not in toolchain_action
assert "hashFiles('pixi.toml')" not in toolchain_action
assert "write-metadata" in fdroid_workflow
assert 'fdroid_sources.py" metadata' in fdroid_workflow
assert "releaseChannels.yml" in fdroid_workflow
assert "verify-index" in fdroid_workflow
assert "--index-v1 repo/index-v1.jar" in fdroid_workflow
assert "--index-v2 repo/index-v2.json" in fdroid_workflow
assert "keytool -printcert -jarfile" in fdroid_workflow
assert "?fingerprint=" in fdroid_workflow
assert "steps.verify.outputs.fingerprint" in fdroid_workflow
assert "release:" not in fdroid_workflow
assert "schedule:" not in fdroid_workflow
workflow_dir = pathlib.Path(".github/workflows")
full_history_checkout = "fetch-depth:" + " 0"
for workflow_path in workflow_dir.glob("*.yml"):
    workflow = workflow_path.read_text()
    assert full_history_checkout not in workflow, workflow_path

assert "fetch-depth: 1" in pipeline_workflow
assert "contents/build-state.json?ref=update" in pipeline_workflow
assert "contents/fdroid/provenance.json?ref=fdroid" in pipeline_workflow
assert pipeline_workflow.count("git fetch --no-tags --depth=1 origin update") == 1
assert 'git worktree add --detach "$worktree" FETCH_HEAD' in pipeline_workflow
assert "fetch-depth: 1" in fdroid_workflow
assert fdroid_workflow.count("git fetch --no-tags --depth=1 origin fdroid") == 1
assert 'git worktree add --detach "$site" FETCH_HEAD' in fdroid_workflow
assert "submodules: true" not in build_workflow
assert "submodules: true" not in build_arch_workflow
assert "uses: ./.github/workflows/build.yml" in pipeline_workflow
for workflow_path in workflow_dir.glob("*.yml"):
    if workflow_path.name == "validate.yml":
        continue
    workflow = workflow_path.read_text()
    assert "actions/" + "setup-java@" not in workflow, workflow_path
    assert "prefix-dev/" + "setup-pixi@" not in workflow, workflow_path
for workflow in (pipeline_workflow, build_workflow, build_arch_workflow, fdroid_workflow):
    assert "uses: ./.github/actions/setup-toolchain" in workflow
assert "fromJSON(needs.plan.outputs.matrix)" in pipeline_workflow
assert "fail-fast: false" in pipeline_workflow
assert "publish_release.py" in pipeline_workflow
assert "fdroid_sources.py check" in pipeline_workflow
assert 'fdroid_sources.py" verify-publish-size' in fdroid_workflow
assert "needs.release.result == 'success'" in pipeline_workflow
assert "uses: ./.github/workflows/fdroid.yml" in pipeline_workflow
assert "BUILD_SOURCE_ONLY" in build_workflow
assert "BUILD_SOURCE_ARCHES_JSON" in build_workflow
assert "Discover Source DAG" in build_workflow
assert "Acquire Version Source" in build_workflow
assert "Expand Version Nodes" in build_workflow
assert "version_fanout.py collect" in build_workflow
assert "No source-ready version node remains" in build_workflow
assert "source-discovery/source-graph.json" in build_workflow
validate_workflow = pathlib.Path(".github/workflows/validate.yml").read_text()
assert validate_workflow.count("pixi run ci-validate") == 1
assert "tests/" not in validate_workflow
assert "scripts/validate-repository.sh" not in validate_workflow
validate_runner = pathlib.Path("scripts/validate-repository.sh").read_text()
assert "tests/*-test.sh" in validate_runner
assert "scripts/toolchain-info.sh" in validate_runner
assert "python3 scripts/validate-repository.py" in validate_runner
assert "fromJSON(needs.collect.outputs.matrix).include" in build_workflow
assert "uses: ./.github/workflows/build-arch.yml" in build_workflow
assert "scripts/build_diagnostics.py source" in build_workflow
assert "scripts/build_diagnostics.py patch" in build_arch_workflow
assert ".version == $version" in build_arch_workflow
assert "--arg version '${{ inputs.version }}'" in build_arch_workflow
assert "BUILD_TARGET" in build_arch_workflow
assert "BUILD_ARCH" in build_arch_workflow
assert "BUILD_MODE" in build_arch_workflow
assert "BUILD_VERSION" in build_arch_workflow
assert "BUILD_OPTIONAL_VARIANT" in build_arch_workflow
assert "BUILD_STOCK_ONLY" in build_arch_workflow
assert "BUILD_STOCK_OUTPUT_DIR" in build_arch_workflow
assert "BUILD_STOCK_SOURCE_DIR" in build_arch_workflow
assert "BUILD_STOCK_OFFLINE" in build_arch_workflow
assert "BUILD_SKIP_CROSS_SOURCE" not in build_arch_workflow
assert "BUILD_STOCK_DIR" in build_arch_workflow
assert "BUILD_PATCH_ONLY" in build_arch_workflow
assert "BUILD_PATCH_OUTPUT_DIR" in build_arch_workflow
assert "BUILD_PATCH_DIR" in build_arch_workflow
assert "BUILD_PACKAGE_ONLY" in build_arch_workflow
assert "fromJSON(inputs.variants)" in build_arch_workflow
assert "Merge and Normalize Stock" in build_arch_workflow
assert "Cross-check Stock Provenance" not in build_arch_workflow
assert "Upload Verified Stock" in build_arch_workflow
assert "needs: verify" not in build_arch_workflow
assert "Apply Patches" in build_arch_workflow
assert "Finalize and Package" in build_arch_workflow
assert "Write Patch Status" in build_arch_workflow
assert "Upload Patch Handoff" in build_arch_workflow
assert "Fail Patch Variant" not in build_arch_workflow
assert "Report Rejected Patch Candidate" in build_arch_workflow
assert "Download Prepared Stock" in build_arch_workflow
assert "Download Patch Handoff" in build_arch_workflow
assert "Read Patch Status" in build_arch_workflow
assert "steps.patch_status.outputs.ready == 'true'" in build_arch_workflow
assert "id: patch_apply" in build_arch_workflow
assert "scripts/capture-build-stage.sh" in build_workflow
assert "scripts/capture-build-stage.sh" in build_arch_workflow
assert "continue-on-error: true" not in build_workflow
assert "continue-on-error: true" not in build_arch_workflow
assert "always() && needs.stock.result == 'success' && needs.patch.result == 'success'" in build_arch_workflow
assert "branch_available" in build_arch_workflow
assert "toJSON(matrix.arches)" in pipeline_workflow
assert 'ANDROID_BUILD_TOOLS_VERSION: "36.0.0"' not in build_workflow
assert 'ANDROID_BUILD_TOOLS_VERSION: "36.0.0"' not in build_arch_workflow
assert 'ANDROID_BUILD_TOOLS_VERSION: "36.0.0"' not in fdroid_workflow
assert "pixi run android-tools" in build_workflow
assert "pixi run android-tools" in build_arch_workflow
assert "APKSIGNER=%s" in pathlib.Path("scripts/ensure-android-build-tools.sh").read_text()
assert "ANDROID_BUILD_TOOLS_VERSION is not configured" in pathlib.Path("scripts/ensure-android-build-tools.sh").read_text()
assert "sudo apt-get" not in fdroid_workflow
assert "libmagic1" not in fdroid_workflow
assert 'import puremagic' in fdroid_workflow
assert 'ANDROID_BUILD_TOOLS_DIR/$tool' in fdroid_workflow
assert 'zipalign -h' not in fdroid_workflow
assert 'apksigner verify --verbose --print-certs "$apk"' in fdroid_workflow
assert 'zipalign -c -P 16 4 "$apk"' in fdroid_workflow
assert 'zipalign -c 4 "$apk"' in fdroid_workflow
assert "publication_artifact" in fdroid_workflow
assert "published-assets.json" in fdroid_workflow
assert "--publication" in pathlib.Path("scripts/sync-fdroid-releases.sh").read_text()
assert "name: variant-build-plan" in pipeline_workflow
assert "pipeline-summary" in pipeline_workflow
assert "pendingDetails" in pipeline_workflow
assert "pipeline-summary.json" in pipeline_workflow
assert "/usr/bin/python3 scripts/ci_summary.py" in pipeline_workflow
assert "scripts/ci_summary.py release" in pipeline_workflow
assert "Summarize Build Plan" in pipeline_workflow
assert "fdroid-publication-summary" in pipeline_workflow
assert "release-publication" in pipeline_workflow
assert "publication_artifact: release-publication" in pipeline_workflow
assert "fdroid_release_gate.py" in pipeline_workflow
assert "Pipeline Health" in pipeline_workflow
assert "actions/upload-artifact@v7" in build_workflow
assert "actions/upload-artifact@v7" in build_arch_workflow
assert "name: result-${{ matrix.variant.resultKey }}" in build_arch_workflow
assert "write-variant-failure.py" in build_arch_workflow
assert "Summarize Source Candidate" in build_workflow
assert "Summarize Stock" in build_arch_workflow
assert "ci_summary.py patch" in build_arch_workflow
assert "ci_summary.py variant" in build_arch_workflow
assert "Summarize F-Droid Changes" in fdroid_workflow
assert "name: fdroid-publication-summary" in fdroid_workflow
assert "actions/download-artifact@v8" in pipeline_workflow
assert "actions/download-artifact@v8" in build_workflow
assert "actions/download-artifact@v8" in build_arch_workflow
assert "actions/download-artifact@v8" in fdroid_workflow
assert "actions/cache@v6" in build_workflow
assert "actions/cache@v6" in build_arch_workflow
assert "patched-kushion-tools-v1-" in build_workflow
assert "patched-kushion-tools-v1-" in build_arch_workflow
assert "patched-kushion-patches-v1-" in build_arch_workflow
assert "actions/cache/restore@v6" in build_workflow
assert "actions/cache/save@v6" in build_workflow
assert "patched-kushion-source-v2-" in build_workflow
assert "actions/cache/restore@v6" in build_arch_workflow
assert "actions/cache/save@v6" in build_arch_workflow
assert "patched-kushion-stock-v2-" in build_arch_workflow
assert "patched-kushion-patch-v2-" in build_arch_workflow
assert "cache_handoff.py source" in build_workflow
assert "cache_handoff.py stock" in build_arch_workflow
assert "cache_handoff.py patch" in build_arch_workflow
assert "inputs.force_build != true" in build_arch_workflow
assert "PATCHED_KUSHION_CACHE_DIR" in build_workflow
assert "PATCHED_KUSHION_CACHE_DIR" in build_arch_workflow
assert "BUILD_PATCH_PROFILE_HASH" in build_arch_workflow
assert "write-all" not in pipeline_workflow
assert "write-all" not in build_workflow
assert "write-all" not in build_arch_workflow
assert "schedule:" in watch_workflow
assert "scripts/fdroid_sources.py check" in watch_workflow
assert "contents/fdroid/provenance.json?ref=fdroid" in watch_workflow
assert "git fetch --no-tags --depth=1 origin fdroid" not in watch_workflow
assert "uses: ./.github/workflows/fdroid.yml" in watch_workflow
assert "APKEDITOR_VERSION=${APKEDITOR_VERSION:-1.4.9}" in pathlib.Path("utils.sh").read_text()