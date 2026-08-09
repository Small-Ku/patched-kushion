# Stable app identities

`package-identities.toml` defines the stable Android package identity for each primary non-root app.
The package name identifies the patched-kushion update channel.
It does not identify a patch project.

Example:

```toml
[apps.KouPhotos]
target = "GooglePhotos-DeVanced"
package-name = "de.kwoo.shion.photos"
display-name = "KouPhotos"
upstream-package = "com.google.android.apps.photos"
```

`config.toml` selects the current patch bundle and patcher for the target.
You can change the target later without changing the stable package name.

## Scope

A stable identity applies only to the selected target's non-root APK.

The builder does these actions:

1. Enable the compatible package-name patch.
2. Set its package-name option.
3. Build the non-root APK.
4. Read the completed package name with `aapt2`.
5. Discard the APK if the package name is not correct.

Current Morphe bundles use `Clone app` for this function.
Older compatible bundles can use `Change package name`.

The builder also manages the GmsCore or MicroG patch when the selected bundle requires it.

The builder searches for `aapt2` in this order:

1. The `AAPT2` environment variable.
2. `PATH`.
3. Repository prebuilts.
4. Android SDK `build-tools`.

Root modules keep the upstream package name.
External mirrored APKs also keep their upstream package name and signature.

A stable-identity target must build `apk` or `both`.
It must also provide a compatible package-name patch.
If it does not, the builder does not publish the non-root APK.

## One primary target

Each app has one primary non-root target.
Two different builds must not use the same package name, version code, and ABI with different APK data.

The current map is:

```text
KouTube   -> de.kwoo.shion.youtube -> YouTube-Morphe
KouMusik  -> de.kwoo.shion.music   -> Music-Morphe
KouPhotos -> de.kwoo.shion.photos  -> GooglePhotos-DeVanced
```

Other targets can exist for tests, comparisons, or root modules.
They do not get the stable package identity unless `package-identities.toml` selects them.

## Public metadata

Keep the patch project name outside the Android package name.
Show the patch project in these locations:

- The app table in `README.md`.
- GitHub Release notes.
- The F-Droid app description.

`scripts/app_catalog.py validate` verifies unique package names and targets.
The validation workflow also verifies that the README app table matches the TOML data.

## Migration rule

A new `de.kwoo.shion.*` package is a different Android app from an old package name.
Users of the old package must install the new package separately.

After you publish a stable package name, do not change it.
Do not replace its APK signing key.
