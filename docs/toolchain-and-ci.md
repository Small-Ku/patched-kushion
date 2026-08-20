# Locked toolchain and CI observability

`pixi.toml` defines the repository toolchain policy and `pixi.lock` is the resolved dependency authority. GitHub workflows do not install a separate JDK or Python runtime.

## Toolchain ownership

The root Pixi environment supplies Python, GraalVM, `fdroidserver`, and their transitive dependencies. `pixi.lock` pins the concrete packages for every declared platform. CI enters that environment through the local `.github/actions/setup-toolchain` composite action, which runs setup-pixi in locked mode and enables its project cache.

The JVM is GraalVM 25. `scripts/toolchain-info.sh` verifies the activated `java` and `keytool` and rejects a non-GraalVM runtime. There is no `actions/setup-java` fallback because a second JVM resolver would create another source of truth and another network bootstrap path.

Android Build Tools remain Google SDK components rather than Conda packages. Pixi still owns their lifecycle: `ANDROID_BUILD_TOOLS_VERSION` and the bounded SDK-manager timeout are activation variables in `pixi.toml`, and the `android-tools` Pixi task runs `scripts/ensure-android-build-tools.sh`. The helper reuses the runner SDK when the locked version is already installed and otherwise asks `sdkmanager` for that exact component. Workflows do not carry their own Android Build Tools version.

The setup-pixi cache restores the locked environment and therefore avoids repeatedly downloading GraalVM/Python packages. This is not a persistent GraalJIT machine-code cache: each new JVM process still profiles and compiles hot code for that process. Long-running or batched JVM work can benefit from GraalJIT warm-up; cross-run reuse currently comes from dependency/tool/input caches rather than saved JIT code.

## Actions summaries

Verbose stage output is diagnostic data, not the primary user interface. Source, Stock, and Patch keep full captured logs in short-lived artifacts, while every stage also writes a compact structured handoff and a `$GITHUB_STEP_SUMMARY` section.

The normal UI therefore exposes:

- `Plan`: release/generation, candidate versions, architecture policy, scheduled outputs, and opportunistic outputs.
- `Source`: whether a version became usable, selected strategy/providers, and available/missing build outputs.
- `Stock`: cache/success/unavailable/failure outcome and the stock source fingerprint when available.
- `Patch`: cache/success/failure outcome with the concrete rejection reason.
- `Variant`: ready/reused/skipped/failed state and published artifact digest metadata.
- `Release`: newly uploaded assets and every required pending variant with target, version, architecture, mode, category, and reason.
- `F-Droid`: why the change gate fired and the provenance records added or removed by publication.

Each Package job uploads a tiny `result-*` metadata artifact independently of the large APK/module artifact. Source jobs similarly upload a `summary-source-*` metadata artifact without the verbose acquisition log. Final aggregation therefore does not download every APK just to report status.

## Final pipeline summary

`Pipeline Health` downloads only the build plan and compact Source/Variant/Release/F-Droid metadata. `scripts/ci_summary.py pipeline` produces both a Markdown job summary and `pipeline-summary.json`, retained as a small artifact for later diagnosis or automation.

The final summary contains stage results, outcome counts, newly published Release assets, failed source candidates, F-Droid changes, and the full pending-required table. A failure such as `PENDING_COUNT=2` is therefore accompanied by the two actual variant keys and their reasons rather than requiring a search through matrix logs.

The summary renderer intentionally uses the Ubuntu runner's built-in Python and only the standard library. This is a recovery boundary: if the Pixi/GraalVM bootstrap itself fails, the final job should still be able to explain the workflow failure. Build, signing, source, release, and F-Droid logic continue to use the Pixi-locked environment.

Candidate incompatibility remains data until publication evaluation. Runner/toolchain infrastructure failures remain failures. The final health job fails once when planning/build infrastructure, Release/F-Droid publication, or a required publication variant is incomplete; optional auto-discovered architectures do not become required solely because they were probed.
