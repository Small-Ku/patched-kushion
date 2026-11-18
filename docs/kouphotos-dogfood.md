# KouPhotos identity dogfood evidence

Observed on 2026-10-03 for this vertical slice. This records artifact evidence and the device acceptance boundary; it does not establish account, backup or complete Photos feature correctness.

| Check | Result |
| --- | --- |
| Locked repository gate | 63/63 passed locally; focused planner test also passed after adding exact-bundle input/cache invalidation cases |
| Kushion Patches MPP | Kotlin fixtures passed; clean rebuild retained identical bytes |
| Upstream functional pass | Real De-Vanced 1.4.4 through Morphe Desktop 1.18.0 |
| Stock input | Read-only pull of official Photos 7.94.0.990335696 signed base, arm64 ABI, xxhdpi and installed language splits; existing builder selected and merged them |
| Upstream intermediate | Package `app.morphe.android.apps.photos`; Mars provider authority and linked host both `app.revanced.android.apps.photos.api.mars` |
| Kushion Patches pass | Real separate Morphe invocation; package `de.kwoo.shion.photos`; both Mars manifest references `de.kwoo.shion.photos.api.mars` |
| Live DEX references | Six Mars instruction references inspected in the upstream intermediate; all six normalized in the Kushion Patches output, including `content://de.kwoo.shion.photos.api.mars` |
| Final artifact at the time | The prior builder launcher-branding step, notice embedding, alignment/signing and independent distribution validator completed; APK signature v3 verification passed |
| Root/module path | Real patch-stage build disabled Clone/GmsCore; package remained `com.google.android.apps.photos`; no Kushion Patches invocation or auxiliary notice source; no distribution Mars authority |
| Phone install | The initial streamed ADB transfer was interrupted when the remote Wi-Fi path dropped. The same 74,485,108-byte APK was then pushed over Tailscale to /data/local/tmp/kouphotos-test.apk; local pm install -r returned Success. No security confirmation was bypassed. |
| Existing phone state | Official Photos and app.revanced.android.photos remained installed. During the test, de.kwoo.shion.photos coexisted with ReVanced Photos and registered de.kwoo.shion.photos.api.mars while the old app retained app.revanced.android.apps.photos.api.mars. After validation the test-signed KouPhotos package and temporary APK were removed; ReVanced Photos remains installed. |
| Phone cold launch/coexistence | am start -W returned Status: ok, LaunchState: COLD, TotalTime: 741, WaitTime: 777; the KouPhotos process remained alive four seconds later. The inspected log window showed normal activity/permission/media events and no KouPhotos FATAL EXCEPTION or AndroidRuntime crash. Account sign-in, backup correctness and complete Mars/Locked Folder behavior remain untested. |

At the time of this dogfood run, the baseline MPP (before the naming-only refactor to Kushion Patches) had SHA-256 `6c5dddae6fdcd4c09b3e7b6e77655e861e2bee247bce4a3d09a087f9f5ff313b`, with source fingerprint `19cd7b1269b3827d0023183e296d2068e1d65e61c15e9ce566b7b707048aea90`. The follow-up naming-only Kushion Patches source fingerprint was `4e32461923f5b81c2ff66756a93d8df2156a3a9110347649f1f3cc86d0169782`; its hosted validation built an MPP with SHA-256 `eb73dac0308aae8889bb1f84c021f103a979d3bf5a72ab3a389c16806d14638b`. These hashes predate Knit launcher resources.

The final arm64 test APK SHA-256 is `31f9d40f389c427afe1dd5d7d82ce3a81ce4081a59f39c554e80a999360cad97`. Its ephemeral test signer certificate SHA-256 is `96d7f848a584098764c73932ee1bfdd5c9d3091e1d9abf451ce616fe20e81c53`. It is not a production-signed distribution artifact. No temporary KouPhotos package remains on the phone.

Morphe's STRIP_FAST output retains old text in unused DEX string-pool entries. Live class/method instruction inspection, rather than a raw byte search, verified that the coupled Mars references were replaced. The manifest validator independently enforces registered authorities/intent hosts and permits legitimate `app.revanced.android.gms` identifiers; GmsCore spoofed package metadata still contains `com.google.android.apps.photos`.

Hosted PR validation and downloadable MPP evidence are available in the [PR checks](https://github.com/Small-Ku/patched-kushion/pull/1/checks). The production Update workflow was not dispatched during dogfood because it also publishes other configured apps. Its exact artifact handoff and cache/input/profile wiring are covered by the focused workflow/planner tests; the local full APK flow and real module patch stage were exercised directly.
