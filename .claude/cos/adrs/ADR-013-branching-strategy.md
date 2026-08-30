# ADR-013: Role-Based Branching Strategy

**Date**: 2026-08-30
**Status**: Accepted
**Deciders**: Kevin Adams
**Supersedes**: ADR-006 (branch-to-channel mapping section only — that ADR's semver scheme is unaffected and still in effect)

## Context

This repo has accumulated three live version lines plus one abandoned one, and the
CI pipeline's branch-to-channel logic never kept up:

- `master` — the original branch. ADR-006 (2026-05-15) declared *"`master` → beta/testing
  channel"* as a permanent rule. `master` was abandoned shortly after v3.0's "clean slate"
  rewrite began on a new branch, and nobody wrote a superseding ADR when that happened.
  As of this ADR, `master` is byte-identical to `release/2.x` (same commit) — a fully
  redundant, silently-stale duplicate that `build.yml` still treated as a legitimate
  testing-channel source.
- `release/2.x` — the actual, intentional archive of the v2.x line, still receiving
  occasional patches for legacy users.
- `release/3.x` — the current, actively-developed v3.x line, and the actual GitHub
  default branch (moved there when v3.0 began, but never renamed to reflect that).
- `release/4.x` — created 2026-08-29 for v4.0.0/Rivendell design work (ADR-012).

**This directly caused a real bug, same day `release/4.x` was created**: `build.yml`'s
version-resolution logic hardcodes literal branch-name comparisons —
`refs/heads/master || refs/heads/release/3.x` for the "testing" channel, everything
else matching `refs/heads/release/*` for "development" — and a separate publish step
did `rm -rf pool/testing` before republishing. The first push to `release/4.x`
matched the generic `release/*` bucket, which shared a publish path with the
`release/3.x`-specific one, and briefly overwrote the public testing apt dist with an
unrelated alpha build (fixed same-day, see ADR-012's Implementation Branch section).

**The structural problem**: every time a new major version's branch becomes "the
current one," someone has to remember to find and update the hardcoded branch-name
literal in `build.yml` (and separately, in README.md, CLAUDE.md, docs/architecture.md,
and the release-notes template). Miss any one of them, and you get exactly the class
of bug above. `ADR-010`'s apt dist-track model (`v2`/`v3`/`v4`/`testing`) already
solves this problem correctly for package *distribution* — dist tracks are named by
fixed suite identity, never renamed, and users never get silently promoted across a
major boundary. Git branch naming had no equivalent discipline.

### Research (2026-08-30)

- **Debian's DEP-14** (git packaging repo layout spec) states the underlying
  principle directly: development branches should be named after their *role*
  (`debian/unstable`, `debian/experimental`), not a value that migrates — DEP-14
  explicitly avoids ever naming a branch `debian/stable`, because "stable" is a
  rolling label pointing at a different codename over time.
- **`openedx/frontend-base` issue #273** hit this exact bug class and fixed it the
  same way this ADR adopts: renamed their always-current branch to a fixed,
  non-version-named identity (`release`), reserving version-numbered branch names
  *exclusively* for already-superseded majors, created only at the moment they're
  demoted.
- **semantic-release** (widely-adopted release-automation tooling) models
  branch-to-channel mapping as declarative, pattern-matched config rather than
  hardcoded literals — its default config auto-recognizes `N.x`/`N.N.x`-named
  branches as maintenance lines via regex, not an enumerated list.
- Node.js and Django both keep the *policy* of which lines are current/maintained/EOL
  in a document or metadata file, never in build-script conditionals.

Full research trail available on request — not reproduced in full here to keep this
ADR focused on the decision.

## Decision

### Branch roles (fixed names, assigned once, never renamed again)

| Branch | Role | Renamed at cutover? |
|---|---|---|
| `main` | The current stable major's development branch (was `release/3.x`) | No — content moves forward, name stays |
| `next` | The in-progress next major, pre-cutover (was `release/4.x`) | No — same |
| `release/N.x` | An **already-superseded** major, archived at the moment it's demoted (e.g. `release/2.x`) | N/A — these are the only branches that ever get a version-numbered name, and only once, at archival time |
| `archive/v2-legacy` | The old `master` branch, retired (was byte-identical to `release/2.x`) | N/A — dead, kept only for discoverability |

`main` and `next` are never renamed. At the next major-version cutover (when `next`'s
content is ready to ship as the new current major): branch `main`'s tip off into a new
`release/{old-major}.x` archive first, then let `main` continue forward as what used
to be `next`'s content, then free up `next` for whatever comes after. No file in this
repo will ever need a branch-name edit for a cutover again — `build.yml`, README, and
every doc reference `main`/`next` by their fixed role name.

### Why not keep `release/N.x` for the current line too (rejected)

The alternative (keep today's naming, just add a config pointer for "which
`release/N.x` is current") was considered and explicitly rejected in favor of the
above — it still leaves version-numbered names carrying a rolling role, which is the
root property DEP-14 and the openedx precedent both identify as the actual defect,
not just a missing pointer. `release/4.x` was one day old with zero external
references when this decision was made, making now the cheapest possible time to fix
this properly rather than defer it to the next cutover.

### What was actually renamed (2026-08-30)

| Old name | New name | Why |
|---|---|---|
| `release/3.x` | `main` | Current stable major; also the GitHub default branch — `main` is the modern idiomatic default-branch name, and this cutover already required retiring the old `master`, making this a natural pairing |
| `release/4.x` | `next` | In-progress v4.0.0/Rivendell work (ADR-012) — not yet a superseded major, so it doesn't earn a `release/N.x` name under this model |
| `master` | `archive/v2-legacy` | Fully redundant with `release/2.x` (same commit); kept renamed rather than deleted so old clones/bookmarks aren't silently broken |
| `release/2.x` | *(unchanged)* | Already correctly named under this model — an archived major that still takes real patches |

All renames used GitHub's branch-rename API (`POST /repos/{owner}/{repo}/branches/{branch}/rename`),
which preserves commit history, auto-updates the default-branch pointer, and redirects
old references — not a delete+recreate.

### `build.yml` changes

- `push`/`pull_request` triggers changed from a bare `["**"]` wildcard to an explicit
  `[main, next, "release/*.x"]` allowlist — closes the "any branch, including a stray
  one, silently triggers full CI" exposure that the wildcard trigger had.
- Version-resolution logic rewritten to match roles, not literals:
  ```bash
  elif [[ "$REF" == "refs/heads/main" ]]; then
    CHANNEL="testing"          # was: refs/heads/master || refs/heads/release/3.x
  elif [[ "$REF" == "refs/heads/next" || "$REF" =~ ^refs/heads/release/.+\.x$ ]]; then
    CHANNEL="development"      # was: refs/heads/release/*
  ```
  A future archived major (`release/5.x`, eventually) is automatically caught by the
  pattern — no code change needed. `next` and archived `release/*.x` branches still
  share one channel/Cloudsmith repo (`truenas-proxmox-snapshots`) for now, same as
  before this ADR; splitting them into separate channels is possible future work, not
  done here, since neither `next` nor `release/2.x` currently has enough push volume
  to need it.
- The "Publish to GitHub Pages testing dist" step already keyed off `channel ==
  'testing'` (fixed same-day as the `release/4.x` incident, see ADR-012) rather than a
  branch-name literal — no further change needed there, it "just worked" once the
  branches were renamed.
- The draft-release template's CHANGELOG.md link changed from a branch-relative link
  (`.../blob/release/3.x/CHANGELOG.md`, which would have gone stale at every cutover
  too) to a tag-relative permalink (`.../blob/${{ github.ref_name }}/CHANGELOG.md`) —
  this step only ever runs on an actual version tag, so the tag name is always
  correct and never needs updating.

### Docs updated to match

`README.md`, `CLAUDE.md`, `docs/architecture.md`, `ROADMAP.md`, and ADR-012 all had
hardcoded `release/3.x`/`master` references — fixed to reference `main`/`next` by
role, except where a reference was genuinely historical (e.g. ROADMAP's record of
what v3.0.0 was released from), which was annotated with the rename rather than
rewritten.

## Consequences

- No file in this repo should ever again need a branch-name edit at a major-version
  cutover — that was the entire point. If a future cutover *does* require touching
  `build.yml`'s branch logic, that's a signal this ADR's model has a gap worth
  revisiting.
- `git checkout main` replaces `git checkout release/3.x` as daily muscle memory —
  a one-time adjustment.
- Apt end users are unaffected — ADR-010's dist tracks (`v2`/`v3`/`v4`/`testing`) are
  already fully decoupled from git branch names; nothing in a user's `sources.list`
  references a branch.
- `archive/v2-legacy` and `release/2.x` currently point at the same commit and will
  drift apart only if `release/2.x` receives a future patch `archive/v2-legacy` does
  not — this is intentional; `archive/v2-legacy` is frozen, `release/2.x` is not.
- The next major-version cutover (v4.0.0/Rivendell shipping) is the first real test
  of this model: branch `main`'s pre-cutover tip into `release/3.x` (recreating that
  name, now correctly meaning "the archived v3.x line"), then let `main` continue as
  `next`'s content. Worth a short runbook entry when that day actually arrives.

## References

- ADR-006 (superseded — branch-to-channel mapping section only)
- ADR-009, ADR-010, ADR-011 (versioning/dist-track/packaging precedent this ADR is
  consistent with)
- ADR-012 (the `release/4.x`→`next` rename and the same-day CI bug this ADR's
  research was prompted by)
- [DEP-14: Recommended layout for Git packaging repositories](https://dep-team.pages.debian.net/deps/dep14/)
- [openedx/frontend-base issue #273](https://github.com/openedx/frontend-base/issues/273) — the closest direct precedent found
- [semantic-release branches configuration](https://semantic-release.gitbook.io/semantic-release/usage/configuration)
