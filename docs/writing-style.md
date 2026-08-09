# Writing style

patched-kushion uses a controlled technical writing style based on ASD-STE100.
The project does not claim formal ASD-STE100 compliance.

Use this style for README files, guides, workflow labels, comments, help text,
and error messages.

## Rules

- Use one term for one meaning.
- Use short sentences.
- Use the active voice when the actor is known.
- Put one action in each instruction.
- Put one main topic in each paragraph.
- Use a vertical list when a sentence contains many items.
- Use positive instructions when possible.
- State a condition before the action that depends on it.
- Do not use unnecessary synonyms.
- Keep code names, file names, package names, and upstream names unchanged.

## Project terms

Use these terms with the meanings in this table.

| Term | Meaning |
|---|---|
| target | One app entry in `config.toml`. |
| variant | One `target × architecture × mode` build. |
| build plan | The set of variants that the current run must build. |
| build state | The record of variants that the project published successfully. |
| release | A GitHub Release that contains build outputs. |
| source | One APK source in `fdroid/sources.toml`. |
| provenance | The record that identifies the source and hash of a published APK. |
| package identity | The Android package name and signing identity of an app. |
| repository identity | The key that signs the F-Droid repository indexes. |

## Preferred verbs

Use these verbs in workflow names, step names, logs, and documentation.

| Use | Do not use when this meaning applies |
|---|---|
| plan | calculate, derive, resolve |
| build | produce, generate an APK build |
| check | probe, inspect for a state change |
| verify | validate after data or a file exists |
| publish | reconcile release assets, push final output |
| save | checkpoint, persist state |
| load | restore or recover state when no recovery operation occurs |
| sync | mirror or copy APK sources into the F-Droid staging area |

Use `recover` only when the system gets valid state from a backup source after
primary state is missing.

## Workflow labels

Keep workflow names short. Use these names:

- `Update`
- `Build Variant`
- `Publish F-Droid`
- `Check F-Droid Sources`
- `Validate`

Use an imperative verb for each step name. Examples are `Load Build State`,
`Create Build Plan`, `Verify Repository`, and `Publish F-Droid Branch`.
