# Update pipeline

The update workflow builds only the variants that need work.
A variant is one `target × architecture × mode` build.

The workflow has six stages:

1. Resolve the patch-supported app version.
2. Inspect which stock artifacts can produce each configured architecture.
3. Add each derivable output variant to the build plan.
4. Build each required variant in an isolated job.
5. Publish each successful result to the current GitHub Release.
6. Publish F-Droid when its published state is not current.

## Build plan

`scripts/pipeline_plan.py` reads `config.toml` and the current build state.
It also checks the GitHub Release assets that the build state references.

The planner calculates an `inputId` for each desired variant.
The ID includes the inputs that can change the output.
These inputs include the app source, split-normalization code, patch bundle, patcher, configuration, and package identity.

The planner treats source artifacts and output variants as different concepts. A universal APK or an `all` APKM/APKS/XAPK artifact can produce architecture-specific jobs. At build time, split containers keep the requested ABI plus every non-ABI split before APKEditor merges them.

A variant does not need a build when all of these conditions are true:

- The build state has the current `inputId`.
- The build state has a GitHub asset ID.
- The referenced release asset still exists.
- The referenced asset has the expected file name.

If one condition is false, the planner adds the variant to the matrix.

The planner writes the matrix as JSON.
GitHub Actions expands this JSON with `fromJSON()`.
The workflow does not contain a fixed list of app jobs.

## Parallel builds

Each matrix job calls `.github/workflows/build.yml`.
The job builds only one variant.

The job has its own checkout, temporary files, Morphe data, and signing files.
This isolation prevents one build from changing another build.

The matrix uses `fail-fast: false`.
A failed variant does not cancel successful sibling variants.

Each successful job uploads a build result artifact.
The result contains the output file, its SHA-256 hash, and its variant data.

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

`scripts/fdroid_sources.py check` compares configured sources with `fdroid/provenance.json`.
The check includes `@self`, sing-box, MicroG RE, and other configured sources.

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
The build jobs run in parallel.
Release writes and F-Droid publication run in sequence.
