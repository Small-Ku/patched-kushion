# Stable non-root app identities

`package-identities.toml` defines the stable Android package used by the primary
non-root build of each logical app. Package names identify the patched-kushion
update channel; they do not identify a patch project.

For example:

```toml
[apps.GooglePhotos]
target = "GooglePhotos-DeVanced"
package-name = "de.kwoo.shion.photos"
display-name = "Google Photos"
upstream-package = "com.google.android.apps.photos"
```

The selected target supplies the current patch bundle and CLI from
`config.toml`. To replace De-Vanced with another compatible Google Photos patch
implementation later, change only `target`. Keep `package-name` unchanged so
existing installations remain on the same app update lineage.

## Scope

Stable identities apply only to the selected target's non-root APK:

- The builder enables Morphe's current universal `Clone app` patch (or the legacy `Change package name` name when using an older bundle) and passes its
  `packageName` option. Google apps continue to use their GmsCore/MicroG patch
  as required by the patch bundle.
- The completed APK is inspected with `aapt2`; a mismatched package is discarded.
- Root modules keep the official upstream package because they replace or mount
  over the stock application.
- Alternative patch targets that are not selected in `package-identities.toml`
  keep the package behavior provided by their own patch bundle.
- APKs mirrored from external GitHub Releases are copied byte-for-byte and never
  renamed or re-signed.

A target selected as a stable identity must build `apk` or `both` and expose a
compatible `Clone app`/package-name patch. The build skips its non-root output
rather than publishing an APK under an unexpected package.

## One primary target per app

Two different patch implementations cannot publish different APK bytes with the
same package name, versionCode, and ABI. Therefore each logical app selects one
primary non-root target. Other targets may remain available for comparison,
modules, or migration testing, but they do not receive the stable identity.

The initial mapping is:

```text
KouTube   -> de.kwoo.shion.youtube -> YouTube-Morphe
KouMusik  -> de.kwoo.shion.music   -> Music-Morphe
KouPhotos -> de.kwoo.shion.photos  -> GooglePhotos-DeVanced
```

## Public metadata

The patch family is intentionally kept outside the package name. It is exposed
through:

- the app catalog in `README.md`;
- GitHub Release build notes;
- the F-Droid app description.

`scripts/app_catalog.py validate` checks that package names and targets are
unique and that every selected target remains a non-root build. The validation
workflow also checks that the generated README catalog has not drifted from the
TOML source of truth.

## Migration warning

Changing from a patch bundle's historical default package to a
`de.kwoo.shion.*` package creates a different Android application. Existing
users of the old package must install the new stable identity separately. Once a
stable package is publicly released, do not rename it and do not rotate its APK
signing key casually.
