# Config

Adding another revanced app is as easy as this:
```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
# or uptodown-dlurl = "https://app.en.uptodown.com/android"
```

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string (e.g. 'Hide ''Get Music Premium''').

## More about other options:

There exists an example below with all defaults shown and all the keys explicitly set.  
**All keys are optional** (except download urls) and are assigned to their default values if not set explicitly.  

```toml
parallel-jobs = 1                    # amount of cores to use for parallel patching, if not set $(nproc) is used
compression-level = 9                # module zip compression level
remove-rv-integrations-checks = true # remove checks from the revanced integrations
dpi = "nodpi anydpi 120-640dpi"      # dpi packages to be searched in order. default: "nodpi anydpi"

patches-source = "revanced/revanced-patches" # where to fetch patches bundle from. default: "revanced/revanced-patches"
cli-source = "ReVanced/revanced-cli"             # where to fetch cli from. default: "ReVanced/revanced-cli"
# options like cli-source can also set per app
rv-brand = "ReVanced Extended" # rebrand from 'ReVanced' to something different. default: "ReVanced"

patches-version = "v2.160.0" # 'latest', 'dev', or a version number. default: "latest"
cli-version = "v5.0.0"       # 'latest', 'dev', or a version number. default: "latest"

[Some-App]
app-name = "SomeApp" # if set, release name becomes SomeApp instead of Some-App. default is same as table name, which is 'Some-App' here.
enabled = true       # whether to build the app. default: true
build-mode = "apk"   # 'both', 'apk' or 'module'. default: apk

# 'auto' option gets the latest possible version supported by all the included patches
# 'latest' gets the latest stable without checking patches support. 'beta' gets the latest beta/alpha
# whitespace seperated list of patches to exclude. default: ""
version = "auto"     # 'auto', 'latest', 'beta' or a version number (e.g. '17.40.41'). default: auto

# optional args to be passed to cli. can be used to set patch options
# multiline strings in the config is supported
patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """

included-patches = "'Some Patch'"                          # whitespace seperated list of non-default patches to include. default: ""
include-stock = "merged"                                   # 'merged', 'split' or 'disable'. default: merged
exclusive-patches = false                                  # exclude all patches by default. default: false

apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://spotify.en.uptodown.com/android"
# direct download url. the url must have point to an apk file with name format shown in this example
direct-dlurl = "https://website/com.google.android.youtube-20.40.45-all.apk"

module-prop-name = "some-app-module"                       # module prop name.
dpi = "360-480dpi"                                         # used to select apk variant from apkmirror. default: nodpi
arch = "arm64-v8a"                                         # 'arm64-v8a', 'arm-v7a', 'all', 'both'. 'both' downloads both arm64-v8a and arm-v7a. default: all
```

## Patch-source-specific apps

A patch source can be paired with its compatible CLI on one app without
changing the defaults used by other apps. For example, Google Photos with
De-Vanced uses the De-Vanced patch bundle and Morphe CLI:

```toml
[GooglePhotos-DeVanced]
app-name = "GooglePhotos"
patches-source = "RookieEnough/De-Vanced"
cli-source = "MorpheApp/morphe-cli"
rv-brand = "De-Vanced"
build-mode = "both"
arch = "both"
apkmirror-dlurl = "https://www.apkmirror.com/apk/google-inc/photos/"
```

The builder automatically enables the patch source's GmsCore/MicroG patch for
the non-root APK and disables it for the root module. This keeps the APK under
the alternate package name while the module patches the installed stock app.

## Stable package identities

Primary non-root package names are configured separately in
[`package-identities.toml`](package-identities.toml), not with a global
`distribution-brand` and not in patch-family-specific target names:

```toml
[apps.GooglePhotos]
target = "GooglePhotos-DeVanced"
package-name = "de.kwoo.shion.photos"
display-name = "Google Photos"
upstream-package = "com.google.android.apps.photos"
```

The target can later move to another compatible patch bundle while the package
name remains unchanged. Only one target per logical app receives the stable
identity. The builder applies it only to non-root APKs through the selected
`Change package name` patch and verifies the final manifest. Google apps still
use GmsCore/MicroG support as required. Root modules and external F-Droid
mirrors are never renamed.

Do not pass `-OpackageName` manually on a target selected by this file. See
[`docs/app-identities.md`](docs/app-identities.md) for migration and coexistence
rules.
