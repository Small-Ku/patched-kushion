# Update pipeline

The update workflow builds only the variants that need work.
A variant is one `app × architecture × mode` build. The matrix still calls the selected app key a `target`, but there is no separate target catalog in `config.toml`.

The workflow has eleven stages:

1. Resolve the patch-supported app version and concrete fallback version candidates.
2. Resolve configured output architectures independently of mirror lag.
3. Group pending variants by app/version and architecture branch.
4. In the source job, inventory broad split-container candidates before any per-ABI fallback. Explicit direct input wins; APKMirror release-wide BUNDLE planning is attempted next, then other reusable split-container sources.
5. Download the smallest complete broad source set once and partition it, or—only when no broad plan works—acquire every required branch payload inside the same source job. If a required branch is still unavailable, try the next compatible version and fail at the source boundary when no candidate works.
6. Fan out architecture jobs and merge/normalize stock from prepared source artifacts only. Architecture stock jobs do not perform primary stock downloads.
7. Cross-check normalized stock against an independent provenance source in a separate verification job.
8. Fan out APK/module patch modes and emit a checksummed patched-APK handoff artifact.
9. Finalize/package each patched artifact separately: launcher branding, required notices, module packing, `zipalign`, final signing, signature verification, and package-identity checks.
10. Publish successful GitHub Release assets and save build state.
11. Publish F-Droid when its state is not current.

## Build plan

`scripts/pipeline_plan.py` reads `config.toml` and the current build state.
It also checks the GitHub Release assets that the build state references.

The planner calculates an `inputId` for each desired variant.
The ID includes the inputs that can change the output.
These inputs include the app source, split-normalization code, patch bundle, patcher, configuration, and package identity.

The planner treats source artifacts, architecture policy, and output variants as different concepts. With no explicit architecture configuration, `auto` probes `universal`, `arm64-v8a`, `arm-v7a`, `x86_64`, and `x86`. A stock variant that cannot currently be produced is an optional unavailable capability, not a failed build, and is probed again on the next update. `arches` and concrete `arch` values remain required outputs.

Aptoide can provide a lightweight current-version hint, while Archive and APKMirror can provide additional hints; failure of any one discovery source does not suppress a job when another source can provide a concrete version. A universal APK or an upstream `all`/`universal` APKM/APKS/XAPK artifact can produce architecture-specific jobs. Split containers are preferred over a compatible standalone APK when they can produce the requested architecture. APKMirror DPI ranges such as `120-640dpi` remain eligible when no explicit `dpi` constraint is configured. Every patched upstream package has a pinned signing certificate; third-party stores/mirrors without a pin are rejected rather than trusted on first use.

Shared-source selection is deliberately **shape-first** rather than mirror-first. An explicit direct split container is authoritative. APKMirror's release-wide planner then gets the first automatic opportunity because it can inventory all APK/BUNDLE rows and select the smallest complete artifact set before payload transfer starts. Its ranking makes BUNDLE format and requested-architecture coverage dominate, then prefers intrinsically broader ABI coverage, lower minimum-Android requirements, and wider density coverage. APKPure through the pinned EFF `apkeep` helper, Archive, and Uptodown remain reusable-container fallbacks. A 403 or missing APKMirror release therefore falls through normally, but a generic store APK is no longer allowed to pre-empt a known broader release bundle merely because its transport is easier to query.

The chosen APKM/APKS/XAPK is downloaded once. `stock_bundle.py partition` extracts each APK member once into a common bucket or one ABI bucket, records SHA-256 digests, and validates upstream signatures before the workflow fans out. At architecture-normalization time, a branch downloads the common artifact plus only its own ABI artifact, verifies the partition digests, and asks APKEditor to merge that materialized set. `universal` materializes all ABI buckets. This rule is source-independent and preserves every language, density, feature, and other non-ABI split while dropping unrelated ABI payloads from architecture-specific outputs.

If no reusable broad container can cover the requested branches, fallback acquisition still happens **once in the source job**. The source stage prepares one branch payload (a standalone APK or selected split set) for each required architecture and uploads that payload as the source artifact. Optional auto-discovered architectures may carry an explicit unavailable marker. A required branch miss causes the source stage to try an older compatible version; it is never delegated to each architecture job as a second network acquisition loop.

A variant does not need a build when all of these conditions are true:

- The build state has the current `inputId`.
- The build state has a GitHub asset ID.
- The referenced release asset still exists.
- The referenced asset has the expected file name.

If one condition is false, the planner adds the variant to the matrix.

Auto variants that report stock-unavailable are intentionally not marked satisfied. Release publication can still complete, but the next scheduled plan probes those variants again. This lets a newly-added upstream ABI join the existing generation without a configuration change. Failures after stock acquisition—patching, notice injection, APK alignment/final signing, or package-identity verification—are not converted into optional skips.

The planner writes the matrix as JSON.
GitHub Actions expands this JSON with `fromJSON()`.
The workflow does not contain a fixed list of app jobs.

## Parallel builds

The planner groups pending variants first by app/version. Each target calls `.github/workflows/build.yml`, whose source job runs once for all pending architectures. The reusable workflow then fans out a matrix of architecture jobs through `.github/workflows/build-arch.yml`. Each architecture workflow has four explicit failure domains: `Stock` merges and locally validates a prepared source without primary network acquisition; `Verify` performs cross-source provenance corroboration; `Patch` applies only the selected patch bundle and writes a checksummed handoff; `Package` performs branding/notices/module packing/final signing and emits the build result. This nested structure lets unrelated targets and ABIs continue independently while making a red job identify the failing responsibility.

For a reusable split source, the source job uploads separate artifacts for metadata, common splits, and each ABI bucket. APK files are already compressed ZIP payloads, so these handoff artifacts use no extra compression. An architecture job downloads only `common + its ABI` (or all ABI buckets for `universal`) instead of downloading the original multi-ABI APKM again. After APKEditor produces normalized stock, the stock artifact contains the merged APK, SHA-256/validation metadata, source/trust provenance, the canonical security fingerprint and cross-source status, plus only the selected split set when `include-stock = "split"` requires it. Patch jobs verify that this metadata still describes the exact stock bytes before trusting the stock-stage handoff.

After stock verification, the architecture workflow fans out one patch job for each pending mode. APK and module patch jobs therefore run in parallel and consume the same verified stock. A successful patch job uploads `patched.apk` plus `patch.json`, whose SHA-256 and target/version/arch/mode fields are checked again by the package job. Packaging cannot silently re-run the patcher when that handoff is missing or corrupt. Package-only execution also skips Morphe CLI/patch-bundle acquisition; patch source/version and any auxiliary notice requirement travel in `patch.json`.

`fail-fast: false` applies both to architecture branches and patch-mode matrices. A failed output does not cancel successful siblings. Optional stock-unavailable results are prepared once and propagated to each pending mode as normal skip results.

Broad-source attempts remain sequential to avoid redundant multi-hundred-megabyte transfers: explicit direct container → APKMirror release-wide plan → APKPure/apkeep split container → Archive container → Uptodown container. Only after all broad plans fail does source-stage branch fallback use `direct → Aptoide → APKPure → Uptodown → Archive → APKMirror`. Aptoide is intentionally a current-version/direct-APK source; APKPure/apkeep can request exact historical versions and architecture selections. Upstream signer validation happens before the source artifact crosses into the stock stage. The stock stage then performs package/version/security fingerprint validation on the normalized bytes.

For every non-direct result—Aptoide, APKPure, Uptodown, Internet Archive, or APKMirror—cross-source verification is opportunistic but isolated in the `Verify` job. The normalized primary APK is fingerprinted from package/version metadata, permissions, manifest component exposure, DEX content, and native libraries. If another independently configured source can produce the same exact version/architecture, it is validated independently and compared. Equality is recorded as corroborated; lack of another available source is non-fatal because the signing certificate is already pinned; a real core-fingerprint disagreement quarantines that stock candidate. Independence is determined from normalized provenance family/domain, not downloader labels, so two paths that ultimately use the same provider do not count as two votes. A disagreement therefore appears as a provenance/verification failure, not later as a patch failure.

The `Patch` job stops after patch application (and any auxiliary package-identity patch) and uploads the checksummed patched-APK handoff. The `Package` job performs every later ZIP mutation, including launcher branding and required notice injection, then runs Android `zipalign` with 16 KiB native-library page alignment, applies the final package signature, verifies that signature, and checks the signed APK alignment again. CI resolves `zipalign` and `apksigner` from the same installed Android Build Tools version when available; the old bundled apksigner JAR is only a local fallback. This keeps patch compatibility failures separate from final APK/package failures and avoids tool-version skew in signing.

Each successful package job uploads a build result artifact. The result contains the output file, its SHA-256 hash, and its variant data.

## Release publication

`scripts/publish_release.py` publishes successful build results.
The script does not mark a failed variant as complete.

A retry for the same build generation uses the same numeric release tag.
This rule prevents one failed architecture from creating an extra release.

The publisher saves `build-state.json` only after it publishes the related release asset.
It also uploads `patched-kushion-build-state.json` to the GitHub Release.

## Build state recovery

The `update` branch contains the primary `build-state.json` file.
A GitHub Release also contains a copy of the state for that generation.

A failure can occur after an asset upload but before the `update` branch push.
In this case, the next run finds the release by its generation marker.
It recovers the state from the release and continues the same generation.

This process prevents duplicate release tags and unnecessary builds.

## F-Droid publication

F-Droid has its own state check.
It does not depend on whether the current workflow built an APK.

`scripts/fdroid_sources.py check` compares selected release assets with `fdroid/provenance.json`.
The check includes this repository's built APK Releases when enabled, plus every app that defines `[apps.<name>.release]`.

If the F-Droid state is current, the workflow stops this stage.
If the state is not current, the workflow calls the `Publish F-Droid` workflow.

This rule also retries a failed F-Droid publication after a successful app release.

## Failure behavior

Only a successful write advances state.
The flow is:

```text
plan
  -> build variants
  -> publish GitHub Release assets
  -> save build state
  -> check F-Droid state
  -> publish F-Droid
```

If a stage fails before it saves its state, a later run retries that stage.
Target source branches run in parallel; each successful source fans out architecture merge/verify work, and each verified architecture fans out its pending patch and package modes in parallel.
Release writes and F-Droid publication run in sequence.
