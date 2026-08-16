# Update pipeline

The update workflow builds only the variants that need work.
A variant is one `app × architecture × mode` build. The matrix still calls the selected app key a `target`, but there is no separate target catalog in `config.toml`.

The workflow has nine stages:

1. Resolve the patch-supported app version.
2. Resolve the configured output architectures independently of mirror lag.
3. Add each required output variant to the build plan.
4. Group pending variants by app/version, with architecture branches nested beneath the target.
5. Probe reusable split-container sources once in reliability order; APKMirror release pages are inventoried only as a late fallback.
6. Download the first suitable broad container once and partition it into common plus ABI-specific split buckets.
7. Fan out architecture jobs, materialize only each branch's required buckets, and merge one normalized stock APK.
8. Fan out pending APK/module patch modes from each architecture's normalized stock.
9. Publish successful GitHub Release assets, then publish F-Droid when its state is not current.

## Build plan

`scripts/pipeline_plan.py` reads `config.toml` and the current build state.
It also checks the GitHub Release assets that the build state references.

The planner calculates an `inputId` for each desired variant.
The ID includes the inputs that can change the output.
These inputs include the app source, split-normalization code, patch bundle, patcher, configuration, and package identity.

The planner treats source artifacts, architecture policy, and output variants as different concepts. With no explicit architecture configuration, `auto` probes `universal`, `arm64-v8a`, `arm-v7a`, `x86_64`, and `x86`. A stock variant that cannot currently be produced is an optional unavailable capability, not a failed build, and is probed again on the next update. `arches` and concrete `arch` values remain required outputs.

Aptoide can provide a lightweight current-version hint, while Archive and APKMirror can provide additional hints; failure of any one discovery source does not suppress a job when another source can provide a concrete version. A universal APK or an upstream `all`/`universal` APKM/APKS/XAPK artifact can produce architecture-specific jobs. Split containers are preferred over a compatible standalone APK when they can produce the requested architecture. APKMirror DPI ranges such as `120-640dpi` remain eligible when no explicit `dpi` constraint is configured. Every patched upstream package has a pinned signing certificate; third-party stores/mirrors without a pin are rejected rather than trusted on first use.

Shared-source selection is deliberately API/tool-first rather than HTML-first. An explicit direct split container is authoritative, then APKPure is queried through the pinned EFF `apkeep` helper with the requested ABI set, followed by Uptodown and Archive. APKMirror is the final shared fallback. If it is reached, the source stage inventories the entire version release page and considers only BUNDLE rows; ranking maximizes requested-architecture coverage, then prefers intrinsically broader ABI coverage, lower minimum-Android requirements, and wider density coverage. This keeps fragile release-page scraping off the hot path while preserving APKMirror's broad-bundle selection when other sources cannot satisfy the request.

The chosen APKM/APKS/XAPK is downloaded once. `stock_bundle.py partition` extracts each APK member once into a common bucket or one ABI bucket, records SHA-256 digests, and validates upstream signatures before the workflow fans out. At architecture-normalization time, a branch downloads the common artifact plus only its own ABI artifact, verifies the partition digests, and asks APKEditor to merge that materialized set. `universal` materializes all ABI buckets. This rule is source-independent and preserves every language, density, feature, and other non-ABI split.

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

The planner groups pending variants first by app/version. Each target calls `.github/workflows/build.yml`, whose source job runs once for all pending architectures. The reusable workflow then fans out a matrix of architecture jobs through `.github/workflows/build-arch.yml`. Each architecture workflow normalizes one stock APK and immediately fans out its pending APK/module patch modes. This nested structure allows one app to enter ABI work as soon as its shared source is ready without waiting for unrelated apps.

For a reusable split source, the source job uploads separate artifacts for metadata, common splits, and each ABI bucket. APK files are already compressed ZIP payloads, so these handoff artifacts use no extra compression. An architecture job downloads only `common + its ABI` (or all ABI buckets for `universal`) instead of downloading the original multi-ABI APKM again. After APKEditor produces normalized stock, the stock artifact contains the merged APK, SHA-256/validation metadata, source/trust provenance, the canonical security fingerprint and cross-source status, plus only the selected split set when `include-stock = "split"` requires it. Patch jobs verify that this metadata still describes the exact stock bytes before trusting the stock-stage handoff.

After stock preparation, the architecture workflow fans out one patch job for each pending mode. APK and module jobs therefore run in parallel and consume the same prepared stock. Each patch job still has its own checkout, temporary files, Morphe data, and signing files.

`fail-fast: false` applies both to architecture branches and patch-mode matrices. A failed output does not cancel successful siblings. Optional stock-unavailable results are prepared once and propagated to each pending mode as normal skip results.

Shared-source fallbacks remain sequential: explicit direct split container, APKPure through `apkeep`, Uptodown, Archive, then APKMirror release inventory. Per-ABI fallback order is `direct → Aptoide → APKPure → Uptodown → Archive → APKMirror`. Aptoide is intentionally a current-version/direct-APK source; APKPure/apkeep can request exact historical versions and architecture selections. A candidate is accepted only after the APK or selected split set passes upstream-signature verification and stock-security fingerprinting. Signer or security rejection now remains inside the source loop, so the next source is still attempted.

For Aptoide/APKPure/Uptodown results, cross-source verification is opportunistic. The normalized primary APK is fingerprinted from package/version metadata, permissions, manifest component exposure, DEX content, and native libraries. If another independently configured source can produce the same exact version/architecture, it is validated independently and compared. Equality is recorded as corroborated; lack of another available source is non-fatal because the signing certificate is already pinned; a real core-fingerprint disagreement quarantines that stock candidate. This keeps the extra check from turning APKMirror anti-bot failures or Archive gaps into a mandatory dependency. Starting every mirror at once would waste bandwidth and increase anti-bot pressure without creating useful build parallelism. When no shared container is available, the architecture branch falls back to the legacy per-ABI acquisition path.

Before a patched APK can become a build result, the patch job performs all ZIP mutations first, including required notice injection. It then runs Android `zipalign` with 16 KiB native-library page alignment, applies the final package signature, verifies that signature, and checks the signed APK alignment again. This ordering prevents a post-signing ZIP mutation from invalidating either the APK signature or `extractNativeLibs=false` native-library layout.

Each successful patch job uploads a build result artifact. The result contains the output file, its SHA-256 hash, and its variant data.

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
Target source branches run in parallel; each successful source fans out architecture merges, and each architecture fans out its pending patch modes in parallel.
Release writes and F-Droid publication run in sequence.
