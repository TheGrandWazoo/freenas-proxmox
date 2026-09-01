# RUNBOOK-002: Pre-Release Checklist

## Purpose

Ensure every release (any `v*.*.*` tag) ships with its documentation already
current — CHANGELOG, ROADMAP, and issue closures — instead of as a follow-up
afterthought once someone asks "what's on the docket." Ref: v4.0.0 release
(2026-08-31), where this exact gap happened — the tag was pushed and the
release published before CHANGELOG/ROADMAP were updated or #243 was closed.

## Background

This project's own workspace rules ("Business decisions in writing",
"Keep docs updated on release") already require this — this runbook exists
because stating the rule wasn't enough to prevent skipping it under the
momentum of "ship it now." The failure mode is specifically **sequencing**:
doing the housekeeping is easy, doing it *before* the tag instead of *after*
is the actual discipline.

None of these steps can be meaningfully automated in CI: the CHANGELOG
`[Unreleased]`→`[X.Y.Z]` conversion is mechanical but would require CI to
commit back to `main` (a new risk category — today's only CI auto-commits
target `gh-pages`, a generated branch, not a source branch). The ROADMAP
"Released" write-up and issue-closing narrative require synthesizing what was
actually tested and shipped — genuinely not scriptable. This is a discipline
checklist, not infrastructure.

## Procedure — before pushing any `v*.*.*` tag

1. **Confirm `$VERSION` in `TrueNAS.pm` matches the tag you're about to push.**
   Mismatches emit a CI warning but still publish — don't rely on CI to catch this.

2. **CHANGELOG.md**: if there's an `[Unreleased]` section for this version,
   convert its heading to `[X.Y.Z] — <today's date>` (drop "in development on
   the `next` branch" or similar in-progress framing). If no `[Unreleased]`
   section exists yet (a smaller release that wasn't tracked incrementally),
   write one now covering what actually shipped.

3. **ROADMAP.md**: move the entry from "Upcoming" to "Released", following the
   exact pattern already established for v3.0.0/v3.1.0/v3.2.0/v4.0.0 — Released
   date, branch, GitHub Release link, "Confirmed tested" table (real versions
   actually exercised, not aspirational), "What shipped" table linking the
   tracking issue(s).

4. **If this is a major-version cutover** (per [ADR-013](../adrs/ADR-013-branching-strategy.md)):
   archive the current `main` into `release/{old-major}.x`, fast-forward `main`
   to the new major's content, *then* do steps 1–3 above on the promoted `main`
   before tagging.

5. **Push the tag.** Let CI build, scan, and publish.

6. **After CI succeeds**: check the GitHub Release it created — it comes up as
   a **draft with template placeholders** (`tested: )`), every time, this is
   expected. Fill in real tested-version data and correct anything the generic
   template gets wrong for this specific release (e.g. a stale Compatibility
   table claiming support for a platform this version actually dropped — this
   happened for v4.0.0's PVE 8.x line). Get explicit confirmation before
   flipping it from draft to published — that's a distinctly more visible,
   less reversible action than the tag itself.

7. **Close the tracking issue(s)** with the version, commit SHA, and doc
   pointers (ADR/CHANGELOG/ROADMAP links) — per this project's issue-lifecycle
   rule. Use a `Fixes #N`/`Closes #N` trailer on a commit that lands on the
   default branch to auto-close, or close manually with the same information
   if the commit already happened without the trailer.

## Pass/Fail

- **Pass:** by the time the GitHub Release is published, CHANGELOG, ROADMAP,
  and the tracking issue(s) are already current — no "docket" follow-up needed.
- **Fail:** any of steps 2/3/7 happening after the tag is already live, as an
  afterthought.
