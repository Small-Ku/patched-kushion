# KouPhotos distribution identity

patched-kushion owns KouPhotos distribution identity and Knit launcher branding. Upstream collections continue to own functional patches, feature spoofing, GmsCore integration, account behavior and backup controls.

The APK pipeline has a semantic boundary between two Morphe invocations:

1. Apply the configured upstream functional bundle.
2. Apply `KouPhotos distribution identity` and `Knit launcher branding` from the in-repo MPP.
3. Embed notices, align and sign, then validate the finished artifact.

The first invocation applies functional patches and the stable package identity. The second invocation applies the distribution manifest contract and Knit launcher resources. Root modules disable upstream clone/GmsCore selection, retain the original package, and do not run the Kushion Patches pass. Other apps keep their existing package-name heuristics and external auxiliary fallback.

The Photos patch has an explicit contract: upstream `com.google.android.apps.photos`, distribution `de.kwoo.shion.photos`, Mars authority and linked intent host `de.kwoo.shion.photos.api.mars`. It accepts stock and known upstream fallback packages. It normalizes known stock/ReVanced/Morphe Mars variants, including `com.google.android.libraries.photos.api.mars` and `app.revanced.android.apps.photos.api.mars`. Unknown or missing Mars structures fail closed.

The small identity core relocates app-prefixed provider authorities and permissions **declared by the app**, plus references to those declarations. It expands relative component class names before changing the install package. Runtime changes are limited to those exact declared identities, exact content URI authorities, recognized Mars aliases, and the incoming functional-patch package. The original Google package literal and GmsCore identifiers remain under upstream control. There is no blanket namespace replacement and no Android extension.

The final validator reads `aapt2` package/XML output independently. It checks the package, MarsStoreProvider authority, linked intent-filter host, and absence of legacy Mars authority/host values. It never repairs an APK. In particular, `app.revanced.android.gms` is a legitimate dependency.

## Build and test

Use the locked Pixi Python/JVM environment and export `GITHUB_ACTOR` and `GITHUB_TOKEN` with read access to Morphe GitHub Packages. Credentials belong in the environment; do not put them in repository files. The template-derived Gradle project pins plugin 1.3.4, Patcher 1.15.0, SMALI and the checksum-verified Gradle wrapper. Maven-local resolution is removed, template examples are stripped, and the repository root remains non-Gradle.

```sh
pixi run bash scripts/build-kushion-patches.sh temp/kushion-patches
pixi run ci-validate
KUSHION_PATCHES_DIR=temp/kushion-patches BUILD_TARGET=KouPhotos BUILD_MODE=apk ./build.sh config.toml
```

The first command runs Kotlin fixtures and produces a bundle plus its source/byte identity. The local full build also requires Android Build Tools and a package-signing identity as described in [package signing](package-signing.md). The final APK must pass the independent manifest contract.

The Update workflow builds once before planning, uploads `kushion-patches`, includes its identity in APK input/profile/patch-asset hashing, and verifies that each consuming APK job received the planned bytes. Module inputs do not depend on this bundle. Generated Gradle outputs do not enter the source fingerprint. External `identity-patches-source` repositories remain supported for fallback package identity. Read-only planner invocations without `--kushion-patches` fingerprint source only; production Update supplies the built handoff.

The bundle manifest uses a fixed timestamp rather than the Gradle plugin's wall-clock timestamp. With the pinned toolchain, unchanged source can retain the same byte fingerprint across builds instead of invalidating patch reuse each day.

The build helper also masks the host Android SDK for this extension-free project and uses the activated Pixi JVM. Otherwise the plugin silently selects the host's newest `android.jar`, changing D8 output despite identical source. Android Build Tools remain required by the APK builder, outside the MPP build process.

## Provenance

The scaffold follows [Morphe's template at 57538a3](https://github.com/MorpheApp/morphe-patches-template/tree/57538a3b85ccd3c9a24ed3cc06ec722787563879). Wrapper files and template notice are retained under GPLv3. The identity implementation is written here; no upstream feature collection or Android extension is copied.

Architecture references: [De-Vanced shared GmsCore](https://github.com/RookieEnough/De-Vanced), [Akash's target-derived Mars fix](https://github.com/Akash-Sriram/morphe-google-photos/commit/4cddf8f), and [rushiranpise's defensive Photos adapter](https://github.com/rushiranpise/morphe-patches). Their GPL/NOTICE files were inspected before implementation. Their functional behavior remains outside this project's identity ownership.

Phone dogfood must preserve official Photos and `app.revanced.android.photos`. Install only the new KouPhotos package, honor device confirmation, verify both Mars authorities and cold launch, and inspect relevant fatal logs. A temporary test signer must be removed afterward so it cannot block the production signer. Passing static tests or cold launch does not establish account, backup or every Mars runtime behavior.

See [dogfood evidence](kouphotos-dogfood.md) for the observed artifact contract, module-path result and device acceptance result and remaining limits for this slice.
