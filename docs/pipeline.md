# Atomic update pipeline

patched-kushion treats publication as desired-state reconciliation rather than as
one monolithic build. A scheduled or manually dispatched run first computes the
variants that should exist, compares them with confirmed release checkpoints,
and builds only the missing or stale variants.

## Build unit

The atomic build key is:

```text
target × architecture × mode
```

For the current configuration this expands to ten independent variants:

- KouTube: APK + module (`all` architecture)
- KouMusik: APK + module for `arm64-v8a` and `arm-v7a`
- KouPhotos: APK + module for `arm64-v8a` and `arm-v7a`

GitHub Actions runs those variants as isolated matrix jobs. `build.sh` receives
`BUILD_TARGET`, `BUILD_ARCH`, and `BUILD_MODE`, so a runner never shares Morphe
temporary data or build output with another variant. `fail-fast` is disabled;
one failed variant does not cancel successful siblings.

## Desired input identity

`scripts/pipeline_plan.py` hashes the inputs that can change the generated
artifact, including the selected patch and Morphe Desktop release assets,
target configuration, stable package identity, and builder/module-template
content. The resulting `inputId` is stored per variant.

A variant is considered satisfied only when all of these are true:

1. its checkpoint has the current `inputId`;
2. the checkpoint records a GitHub release asset ID;
3. that exact immutable asset ID and filename still exist in the release.

A deleted release asset therefore schedules a rebuild even if upstream inputs
have not changed.

## Partial success and retry

Each successful matrix job uploads one workflow artifact containing the built
APK/module and `result.json`. `scripts/reconcile_release.py` consumes whichever
jobs succeeded and updates only their checkpoints. Failed variants retain their
old checkpoint, or no checkpoint for a new variant.

The next planner run consequently emits only the unsatisfied variants. A retry
of the same desired generation reuses the same numeric GitHub release tag, so a
single failed architecture does not create a second release generation.

When a new generation is created, previously confirmed artifacts are copied
forward as known-good fallbacks until their replacement succeeds. A stale
fallback is never marked as satisfying the new `inputId`.

## Checkpoint recovery

The canonical checkpoint is `build-state.json` on the `update` branch. The
reconciler also uploads `patched-kushion-build-state.json` to the corresponding
GitHub Release and puts a generation marker in the release notes.

This handles the failure window where release assets were uploaded successfully
but pushing the `update` branch failed. On the next run the planner finds the
release by generation marker, restores the release checkpoint, and continues
that release instead of opening a duplicate tag or rebuilding already-confirmed
variants.

## F-Droid is a separate reconciliation layer

F-Droid publication is not gated on whether a build job ran in the current
workflow. After release reconciliation, `scripts/fdroid_sources.py probe`
compares every configured source — including `@self` — with the successfully
published `fdroid/provenance.json` state.

Therefore a previous F-Droid failure is retried even when patched-app upstream
inputs are unchanged. External source watching uses the same comparison, so
sing-box, MicroG RE, and self-built APKs all converge through one provenance
model.

## Failure semantics

Only successful durable writes advance state:

```text
planner
  -> isolated atomic builds
  -> GitHub Release reconciliation
  -> update/build-state.json checkpoint
  -> F-Droid provenance reconciliation
```

A failure before a layer's checkpoint leaves that layer pending and causes a
future run to retry it. Expensive patching is parallel; release/update-branch
writes and F-Droid publication remain serialized.
