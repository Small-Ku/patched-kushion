# Repository development workflow

## Authority and worktree safety

- `main` is canonical accepted history. Start normal work from the latest `main` in a short-lived branch or isolated worktree.
- Do not disturb another active worktree. Never stash, reset, clean, switch away from, or overwrite foreign in-progress work to make room for a task.
- One PR should carry one independently reviewable logical change.
- Keep unrelated pipeline, packaging, F-Droid, source-acquisition, identity, or cache changes separate unless one cannot be safe without the other.

## PR opening and review

- Exploration may stay local while feasibility or value is unknown.
- Open the first correct authority PR when all three conditions hold:
  - the direction is technically feasible;
  - it is materially useful for the stated goal;
  - no known blocker is likely to overturn it.
- PR-ready is not implementation-complete.
- Continue remaining validation and review work on the same PR.
  - This includes source/provider coverage, APK variants, F-Droid checks, packaging/signing validation, cache validation, cleanup, documentation, and review fallout.
- Treat PR branch commits as evolving review/evidence carriers. Prefer additive corrective commits during review; do not rewrite published history solely for cosmetics.
- Do not create a successor or replacement PR merely to obtain a cleaner branch or new PR number. Recover the existing authority PR when possible.

## Validation and canonical history

- Validate affected pipeline stages with real artifacts and the repository's existing checks.
- Do not describe planning, compilation, metadata discovery, or one successful architecture as broader runtime/package acceptance than was actually exercised.
- Preserve existing signing and release boundaries. Never expose signing secrets or move private release state into repository history.
- The accepted tree is the finalization authority.
- After review accepts it, the maintainer uses `Merge-NyaGitHubPullRequest` to create the canonical squash result.
- Intermediate agent commits need not be canonical or signed.
- Do not merge the PR on the maintainer's behalf unless explicitly instructed.

In short:

> Validated direction -> open the PR. Accepted tree -> maintainer squash later.
