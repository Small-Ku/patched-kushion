# Update pipeline

The update workflow builds only variants that need work. A variant is one `app × architecture × mode` output. The matrix still calls the selected app key a `target`, but there is no separate target catalog in `config.toml`.

The pipeline deliberately separates network acquisition, stock materialization, patching, final packaging, and publication:

1. `Plan` resolves patch-supported version candidates, architecture policy, immutable patch assets, and pending output variants. For the normal `version = "auto"` path it does not query stock providers; that network boundary belongs to Source.
2. `Source` has a metadata-discovery phase once per app, then fans out independent acquisition jobs per candidate version. The DAG includes patch-declared candidates and, for `version = "auto"`, up to `forward-compatibility-probes` provider-advertised versions newer than the declared boundary. Each version validates upstream signer pins and performs cross-source corroboration independently; a failed forward probe cannot block a declared candidate.
3. `Stock` fans out by architecture. It has no primary stock network path and no signing secret. It materializes only the prepared source payload, merges split sets without release signing, fingerprints the normalized bytes, and emits an immutable stock handoff.
4. `Patch` fans out by patch profile. It verifies the stock handoff, applies only the selected patch bundle and auxiliary identity patch when required, and emits `patched.apk` plus a checksummed `patch.json` contract.
5. `Package` performs every later APK mutation: launcher branding, required notices, module packing, `zipalign`, final APK signing, signature verification, alignment verification, and package-identity checks.
6. `Release` combines successful results with compatible previous assets, applies publication consistency, updates the GitHub Release, and only then advances build state.
7. `Release` also emits a compact publication handoff containing the assets uploaded by this run. F-Droid consumes that handoff before its normal Release-API/provenance comparison, so newly published APKs do not depend on immediate API consistency.
8. F-Droid is checked and published independently when either the publication handoff contains an eligible APK or its persisted provenance is stale.

Candidate rejection is data until final publication evaluation. Source/Stock/Patch candidate commands are captured into diagnostic artifacts and report status handoffs rather than failing every downstream matrix node. The handoff also classifies recognized failures and retains bounded evidence/provider attempts, so later stages do not have to reinterpret the raw log. Each stage emits a compact GitHub job summary. After every compatible version/source candidate has finished, one final `Pipeline Health` job aggregates only small metadata handoffs and fails when planning/build infrastructure, publication infrastructure, or a required publication variant is incomplete. Its summary separates the logical requirement from the candidate that reached the furthest stage and lists the complete candidate-attempt history, so a failure belongs to one domain instead of cascading through later stages or requiring manual log archaeology.

## Build plan

`scripts/pipeline_plan.py` reads `config.toml` and the current build state. The workflow reads `update/build-state.json` through the GitHub Contents API; it does not fetch the `update` branch merely to inspect one file. The branch is shallow-fetched only when a successful release actually needs to write new state.

For patch-pinned/`auto` targets, the planner does not query Archive, APKMirror, Aptoide, APKPure, or Uptodown for stock availability. It resolves the patch-declared candidate set and a forward-probe budget; Source performs the cross-provider comparison later. Provider-advertised versions newer than the declared boundary are therefore evidence-driven probes rather than versions guessed by the planner. (`latest`/`beta` still require lightweight pre-plan version discovery because the current state schema needs a concrete version before an `inputId` can be constructed, and forward probing is disabled for those explicit policies.)

The planner calculates an `inputId` for each desired variant. The ID covers inputs that can change the output, including stock/version policy, split-normalization code, patch assets, patcher, configuration, and package identity. It also calculates two patch-specific hashes:

- `patchAssetHash` identifies the resolved CLI/patch release assets and is suitable for a verified prebuilt cache key.
- `patchProfileHash` identifies mode-dependent patch semantics, stock preprocessing, package-identity/GmsCore policy, patch configuration, and patch assets. A Package job refuses a patch handoff produced for another profile.

APK and module profiles currently differ: module input strips native libraries while APK input keeps the selected architecture, and their package-identity/GmsCore policies differ. They therefore remain separate patch jobs. The hash contract makes future deduplication safe if two profiles ever become genuinely identical instead of assuming that two modes can share patched bytes.

### Architecture priorities

Source planning distinguishes publication optionality from acquisition priority. Explicitly configured architectures are `required`: a compatible version is rejected when one is missing. Auto-discovered architectures remain optional publication capabilities, but their source priority is `desired`: the broad-source planner tries to cover as many of them as possible before accepting a narrower candidate. A true `optional` source priority is supported for capabilities that should have even lower acquisition weight.

With no explicit architecture configuration, `auto` probes `universal`, `arm64-v8a`, `arm-v7a`, `x86_64`, and `x86`. A currently unavailable auto ABI is probed again on a later update rather than being marked permanently satisfied.

## Source acquisition DAG and Bundle-first planning

`Source` does not use the downloader adapter array as a first-success fallback chain. Before stock payload transfer it probes **every configured provider** for version metadata in parallel and persists the observations plus the resulting dependency graph as `source-graph.json`. The graph has discovery nodes, patch-compatible version nodes, reusable broad-acquisition nodes, and per-ABI branch nodes. Edges make the intended order inspectable instead of hiding it in nested shell loops.

`Plan` defines the patch-declared version candidate set. Source compares provider observations first and may prepend a bounded set of advertised versions newer than the newest declared candidate. These nodes are marked `forward-probe`, not silently promoted into the patch compatibility declaration. Declared versions explicitly advertised by at least one provider outrank declared versions that can only be blind-probed. A provider whose metadata endpoint fails or cannot enumerate versions remains an explicit low-priority probe node, because an exact-version download endpoint can still work. This avoids both extremes: a flaky listing endpoint does not erase a viable transport, but an adapter's position in a shell array no longer decides the chosen version.

For each version node, the DAG traverses reusable broad candidates before expanding ABI-specific nodes. Broad candidates are still shape-first: APKMirror can plan release-wide Bundle/APKM/APKS rows without payload transfer, APKPure can request multiple ABIs through `apkeep`, and Archive/Uptodown/direct transports can expose reusable containers when available. A complete one-artifact candidate terminates broad traversal because later nodes cannot improve requested coverage or download count. If a broad node only covers part of the desired auto-ABI set, Source continues to later broad nodes before falling back to branch acquisition.

APKMirror is especially useful because its release page can be inventoried before payload transfer. `scripts/source_plan.py` evaluates release rows, hard-gates required architecture coverage, then ranks plans by desired coverage, true optional coverage, total requested coverage, fewer artifacts, Bundle breadth, Android compatibility, and density breadth. It can therefore choose one broad Bundle rather than independent ABI APKs when both exist.

Other providers return a broad candidate when their transport supports it. The generic source evaluator accepts either a split container or a reusable standalone APK, but **runtime ABI compatibility is not treated as derivability**. A flattened standalone APK has lost the split boundaries required for clean ABI-selective normalization: an ABI-independent or genuinely multi-ABI APK can back only `universal`, while a standalone APK with exactly one native ABI can back only that ABI. Split containers may back each ABI that can actually be materialized. `universal` is advertised only for ABI-independent containers or containers with more than one concrete ABI; a single-ABI APKM is therefore never relabeled as universal. APKMirror-planned standalone artifacts are re-inspected after download, so incorrect store metadata cannot turn a fat APK into a fake ABI-specific branch.

A partial broad result is useful rather than terminal. Source preserves the branches it can derive (for example an APKPure fat APK as `universal`) and continues the DAG only for the missing desired/optional architectures. Partitioned broad containers are materialized into self-contained branches before results from another provider are mixed in, producing one hybrid branch plan with per-branch provenance. Within each missing architecture, Source evaluates every successful provider candidate instead of stopping at the first runnable APK: a validated split container outranks a flattened standalone, and smaller candidates win within the same representation class. This lets a later APKM/APKS/XAPK source replace a much larger store-flattened APK without sacrificing language/density/feature splits.

If no broad DAG path satisfies the required capabilities, that version's acquisition job expands its architecture nodes. Each architecture traverses only providers represented by the discovery graph for that version: positive version advertisements first, then explicit probe nodes. Acquisition-time metadata failures are negatively memoized for that provider/locator, so a listing endpoint blocked by a WAF is not retried once per missing ABI. A downloaded payload that is proven unusable for a requested branch (for example a store returns an arm-v7a split bundle for an arm64 request) is also memoized by provider/version/architecture/content SHA within that acquisition run; the identical payload is not re-inspected as the same architecture candidate. The rejection stays branch-specific and does not poison another ABI/provider or weaken signer/security checks. This is search-graph traversal after a global discovery phase, not a provider-array fallback policy. Candidate versions are separate matrix nodes, so an acquisition or patch failure on one version does not cancel siblings; only source-ready versions fan out into Stock/Patch/Package.

`source.json` schema v2 records the selected path's status, requested/available capabilities, required/desired/optional coverage and misses, chosen source/strategy, and acquisition-time verification. `source-graph.json` records the wider search that led to that choice, including versions discovered outside the current patch-compatibility boundary for diagnostics. Stage-only execution checks `source.json.status`; the existence of metadata alone is never success.

## Source trust and provenance

Every third-party upstream package has a pinned Android signing certificate. Split containers are checked split-by-split before merge. Source acquisition then produces a canonical stock security fingerprint from package/version metadata, permissions, exposed manifest components, DEX content, and native libraries. ZIP metadata and signing-block bytes are intentionally excluded from the comparison digest.

Cross-source verification belongs to `Source`, because it answers whether the acquired upstream bytes are credible. For a source that requires corroboration, the source stage tries an independently configured provider of the same exact version/architecture. Independence is based on normalized provenance family/domain rather than downloader label, so two URLs that ultimately use the same provider do not count as two votes. A matching canonical fingerprint is recorded; no independent source is non-fatal when the upstream signer pin and local fingerprint are valid; a real fingerprint disagreement quarantines that candidate and can cause source selection to try another candidate/version.

There is intentionally no separate `Verify` matrix job. Stock does not re-download another store, and provenance checking can no longer accidentally invoke split acquisition, merge, or signing on every ABI runner.

## Offline stock materialization

After Source, each architecture job downloads only its prepared handoff. A partition strategy downloads `common + its ABI` buckets; `universal` downloads every ABI bucket that Source actually advertised. A branch strategy downloads only that branch payload.

APKEditor merge is explicitly unsigned at this stage. `merge_split_dir_unsigned` does not call `sign_apk`, so Source and Stock do not need package signing secrets. The Stock job runs with `BUILD_STOCK_OFFLINE=true`, validates the source verification handoff, normalizes the selected split set, calculates a security fingerprint for the exact merged bytes, and exports `stock.apk`, `stock.json`, and `stock.security.json`. Only the selected split set is retained when a module explicitly needs embedded stock splits.

The old hidden `merge → release sign` side effect is forbidden because it made Source, Stock, and provenance checks depend on `APK_KEYSTORE_PASSWORD` merely to inspect a split set.

## Patch and package handoffs

Patch verifies the SHA-256 and metadata of the Stock handoff before using it. Morphe still signs its intermediate as part of patch execution, but that intermediate is not a published artifact. Patch stops before branding, NOTICE injection, APK final alignment, release finalization, or module packing.

A successful Patch job uploads `patched.apk` and `patch.json`. The metadata contains target, package, version, architecture, mode, SHA-256, patch source/version, auxiliary NOTICE requirements, and `patchProfileHash`. Package verifies all of these fields before accepting the handoff. Package-only execution does not reacquire the Morphe CLI or patch bundle and cannot silently re-run the patcher if the handoff is missing.

Package then performs all final ZIP mutations and runs:

```text
launcher branding / required NOTICE mutation
→ zipalign -P 16 -f 4
→ final package signature
→ apksigner verify
→ zipalign -c -P 16 4
```

CI resolves `zipalign` and `apksigner` from the same Android Build Tools version. The bundled apksigner JAR remains only a local fallback. This keeps patch fingerprint failures in Patch and alignment/signing failures in Package.

`fail-fast: false` applies to architecture and patch/package matrices. Package uses `always()` with a Stock-success gate and independently attempts to download each matching patch artifact, so one failed patch mode does not suppress a successful sibling mode.

## Publication consistency and fallback

Successful variants are combined with known-good previous assets. A previous asset counts as reusable only when its version-specific `inputId` is still compatible with the current plan and the release asset still exists. One base variant (`app × architecture × mode`) may have several successful app versions in the same Release: all are retained as assets, while `build-state.json::variants` points at the newest compatible version for consumers that need one preferred result. `artifactsByInputId` indexes every compatible published result so a later scheduler run can skip Stock/Patch/Package for an already-built input.

`publish-consistency` supports `variant`, `target`, and `global`. The repository default is `target`. If any **required** variant for an app has neither a new success nor a compatible previous fallback, newly successful results for that same app are held rather than publishing an accidental half-update. Auto-discovered optional ABIs do not block the target. Other apps remain independent, so one broken target still does not prevent unrelated releases.

Held outputs are reported separately from unavailable auto variants and pending failures in `build-state.json` and the Release notes. State advances only after the corresponding assets have been published.

A retry for the same generation reuses the same numeric release tag. The Release also carries `patched-kushion-build-state.json`, so a later run can recover after an asset upload succeeded but the `update` branch write failed.

## Cache policy

Actions cache is a disposable cross-run acceleration layer; every restored handoff is validated before it can enter the next DAG stage:

- `apkeep` and APKEditor use a helper cache under `PATCHED_KUSHION_CACHE_DIR/tools`. Automatically downloaded entries are looked up from pinned GitHub release metadata and revalidated against the release SHA-256 before execution. An executable without a usable release digest is job-local and is not persisted.
  The workflow also uses a runner/architecture restore prefix, so harmless helper-code edits can reuse older versioned entries; digest validation still gates execution and a valid hit is not downloaded again.
- Morphe/Piko/De-Vanced CLI and patch assets use `PATCHED_KUSHION_CACHE_DIR/patches`, keyed by the planner's `patchAssetHash`. Cached release assets are revalidated against GitHub's release digest; assets whose release metadata has no digest remain job-local.
- Successful Source payloads are cached by app/version, requested architecture coverage, source URLs/policy, signer pins, stock-security policy, and source implementation digest. Patch release metadata is intentionally excluded, so updating only Piko/Morphe/De-Vanced does not redownload an unchanged upstream APK/APKM/XAPK. The restored `source.json` and payload layout are checked before reuse.
- Prepared Stock handoffs are cached independently per version/architecture and Source cache identity. `stock.apk`, its SHA-256, and its security fingerprint must agree before a cache hit can bypass split merge/normalization.
- Successful Patch handoffs are cached by version-specific `inputId`, exact prepared-stock SHA-256, and the public signing-certificate SHA-256. This cache crosses workflow runs and release generations, preventing an unrelated app update from applying the exact same patch operation again. A new patch bundle/profile changes `inputId`; changed stock bytes change the stock digest; rotating the signing identity changes the certificate digest. Any of those naturally misses the cache. Manual `force_build=true` bypasses the Patch-result cache but may still reuse already verified Source/Stock inputs. Final Package still runs for a new generation, which is important because module `versionCode` follows the numeric Release tag.
- Every toolchain-consuming job enters the same setup-pixi project cache. `pixi.lock` pins Python, GraalVM 25, `fdroidserver`, and transitive packages, so there is no parallel `setup-java`/system-Python dependency graph. Android Build Tools stay official SDK components, but their version and bounded `sdkmanager` lifecycle are exposed through the Pixi `android-tools` task.

Private signing material is never cached; only its public certificate fingerprint participates in a Patch cache key. GitHub Release assets remain the publication/state boundary rather than being treated as an Actions cache. Pixi cache reuse restores the JVM distribution and environment, not GraalJIT-compiled machine code from a previous runner process.

## F-Droid publication

F-Droid state is independent of whether the current run built an APK. `pipeline.yml` and `fdroid-watch.yml` read `fdroid/provenance.json` with the GitHub Contents API rather than fetching the `fdroid` branch just to inspect one file. The F-Droid workflow still performs a shallow fetch/worktree only when it must update and push that branch.

`scripts/fdroid_release_gate.py` first checks the exact APK assets uploaded by the current `Release` job. Assets over `max-repo-asset-size` stay on GitHub Release but do not trigger the Git-backed F-Droid repository. This direct handoff closes the short consistency window in which an immediately repeated GitHub Releases API query may not yet expose a just-uploaded asset. `scripts/fdroid_sources.py check` still compares the full selected Release asset set with F-Droid provenance, covering external releases, old missed publications, and later state refreshes. If neither check changes anything, publication stops. Otherwise the reusable F-Droid workflow verifies the selected assets, updates the repository, and pushes state. Its Pixi environment is cached, but the F-Droid repository signing identity is never cached.

## Failure behavior

Only successful writes advance state. The effective flow is:

```text
Plan
  → Source + provenance verification
  → offline Stock materialization
  → Patch
  → Package
  → Release publication / target consistency
  → save update state
  → check F-Droid state
  → publish F-Droid when needed
  → final publication health
```

Targets run independently. Source discovery runs once per target; candidate versions then acquire in parallel, each source-ready version fans out architecture Stock jobs, and each stock branch fans out its required Patch/Package modes. Routine candidate misses and compatibility rejections remain ordinary diagnostic output; their full stage logs are retained in handoff artifacts while the console prints only a bounded tail. Downstream stages read explicit ready/failed handoffs and skip rejected candidates instead of repeating the same error. Compact Source/Variant metadata is uploaded separately from large payload artifacts, and final Pipeline Health renders a Markdown/JSON summary before evaluating the exit status. A red final-health job therefore states which required publication output remains pending and why.
