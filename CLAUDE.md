# freenas-proxmox — Claude Code Guide

## What This Project Is

A storage plugin "wedge" for Proxmox VE (PVE) that allows PVE to manage iSCSI LUNs on TrueNAS/FreeNAS via the TrueNAS REST API instead of the traditional SSH-based `iscsiadm` approach.

The plugin installs as a Debian package and works by:
1. Deploying a new Perl LunCmd handler (`FreeNAS.pm`) to `/usr/share/perl5/PVE/Storage/LunCmd/`
2. Patching three Proxmox VE system files at install time via `dpkg triggers`

## Repository Layout

```
freenas-proxmox/
├── perl5/PVE/Storage/
│   ├── Custom/FreeNAS.pm          # Old attempt at a full custom storage type (unfinished)
│   ├── LunCmd/FreeNAS.pm          # MAIN backend: iSCSI LunCmd via TrueNAS REST API
│   ├── LunCmd/FreeNAS-ng.pm       # Next-gen draft (not in use)
│   └── ZFSPlugin-*.pm.patch       # Per-PVE-version patches for ZFSPlugin.pm
├── pve-manager/js/
│   └── pvemanagerlib-*.js.patch   # Per-PVE-version patches for the Proxmox UI JS
├── pve-docs/api-viewer/
│   └── apidoc-*.js.patch          # Per-PVE-version patches for the API docs JS
├── perl5/REST/Client.pm           # Bundled REST::Client (also an apt dependency)
├── stable-5/, stable-6/, stable-7/, stable-8/
│                                  # Per-major-version snapshots of patches + originals
└── .github/workflows/action.yml   # Currently just dispatches to external packer repo
```

## How the Current Build Works (Two-Repo Problem)

1. A push to this repo triggers `action.yml` which fires a `repository_dispatch` event to `TheGrandWazoo/freenas-proxmox-packer`
2. That separate repo holds the DEBIAN package structure (`DEBIAN/control`, `postinst`, `postrm`, `triggers`)
3. Its CI builds the `.deb` with `dpkg-deb` and pushes to Cloudsmith

The `postinst` script at install time **git-clones this repo** to `/usr/local/src/freenas-proxmox` and applies patches from there. This is the key fragility — internet access required at package install time.

## Three Files That Get Patched at Install Time

| File | What the patch adds |
|------|---------------------|
| `/usr/share/perl5/PVE/Storage/ZFSPlugin.pm` | Adds `freenas` as a valid iSCSI provider, routes `run_lun_command` to `FreeNAS.pm`, adds custom properties/options |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | Adds `FreeNAS/TrueNAS API` to the iSCSI provider dropdown; adds UI fields for API host, user, secret, SSL, token auth |
| `/usr/share/pve-docs/api-viewer/apidoc.js` | Registers TrueNAS-specific properties in the API docs |

## Authentication Modes Supported

- **Basic Auth**: `freenas_user` + `freenas_password` (deprecated but still works)
- **Bearer Token**: `truenas_token_auth=true` + `truenas_secret` (preferred for TrueNAS SCALE)

## TrueNAS API Version Detection

The plugin auto-detects v1.0 vs v2.0 API based on the TrueNAS version string and HTTP response:
- `>= 11.03.01.00` → uses v2.0 API
- Older → uses v1.0 API

## Known Issues / Active Work

- Versioned patches are fragile — each PVE minor release may need a new patch
- `postinst` clones the repo at install time (requires internet, fragile)
- `Custom/FreeNAS.pm` is unfinished (duplicate `properties()` and `options()` subs)
- REST::Client is both an apt dependency AND manually bundled
- Everything is named `FreeNAS` internally but the product is now `TrueNAS`
- SSH keys still required for ZFS pool listing (separate Proxmox code path via `ZFSPoolPlugin.pm`)
- Max LUN limit bug (#150)

## Key Perl Modules

- `PVE::Storage::LunCmd::FreeNAS` — the main plugin. Entry point: `run_lun_command()`
- Functions: `freenas_api_connect`, `freenas_api_check`, `freenas_api_call`, `freenas_list_lu`, `run_create_lu`, `run_delete_lu`, `run_modify_lu`

## Packaging / Deployment Notes

- Package name: `freenas-proxmox`
- Apt repos: Cloudsmith (`ksatechnologies/truenas-proxmox` stable, `ksatechnologies/truenas-proxmox-testing` beta)
- Install: `apt install freenas-proxmox` after adding the repo
- The package uses dpkg `triggers` to re-apply patches when Proxmox VE packages are upgraded

## ADRs / Plans / Runbooks

See `.claude/cos/adrs/` for Architecture Decision Records.
See `.claude/cos/plans/` for implementation plans.
See `.claude/cos/runbooks/` for operational runbooks.

---

# KSA Workspace Standards

> Baseline rules for all KSA Technologies Claude workspaces.
> Source of truth: `/mnt/c/Users/Kevin/OneDrive - ksatechnologies.com/workspace/claude-scaffold/CLAUDE.md`

## Environment

- **Shell:** WSL (Linux). Always use bash/Linux syntax — `export VAR=value`, forward slashes, `source .venv/activate`. Never PowerShell, never cmd.exe.
- **OS:** WSL2 on Windows. Paths under `/mnt/c/Users/Kevin/OneDrive - ksatechnologies.com/workspace/`.

## Agent / Minion Rules

- **Minions are research-only.** They search, read, and web-fetch. They return findings to main Claude. They never write files, commit, push, or delete.
- **Minions do not talk to each other.** All findings route through main Claude.
- **Main Claude does all writing, committing, and pushing.**

## File Rules

- **New files:** write freely.
- **Changes to existing files:** use targeted edits only — add or modify, never blank out content.
- **Total replacement of an existing file:** write the replacement as a NEW file first, explain to the user why the old file needs replacing, wait for explicit approval. Never silently overwrite.
- **Briefs and reports:** always new dated files. Never overwrite a previous brief. The historical record grows forward, never shrinks.

## Permission Levels

| Actor | Permissions |
|---|---|
| **User** | Full control — can do anything including delete |
| **Main Claude** | Pre-approved: read, write, edit, commit, push, gh CLI. Must ask before any delete unless user has explicitly pre-authorized it. |
| **Minions** | Research only — read, search, web-fetch. No write, commit, push, or delete. |

## Workflow Order

Always follow this sequence. Never skip ahead:

1. **Open a GitHub issue** — captures the problem/feature before any code
2. **Update design/architecture docs** — ADR if warranted, roadmap, architecture
3. **Implement code** — with tests
4. **Update docs** — test-scenarios, user examples, troubleshooting callouts
5. **Close the issue** — with version, commit, and doc pointers

## Documentation Discipline

Every feature, breaking change, or config change ships with:
- Code + tests
- Test-scenario examples
- Troubleshooting callouts where relevant
- Architecture/design doc update if the shape changed
- ADR if a significant technology decision was made
- Roadmap `Resolved` update

Never ship a feature without its docs.

## Issue Lifecycle

- Close issues when work ships — include version, commit SHA, and doc pointers
- User-filed bugs: add `fixed — awaiting-feedback` label if user confirmation needed
- Dependabot patch/minor: merge when CI is green (ad-hoc, no milestone)
- Dependabot major: open an issue, add to a milestone, test intentionally
- Dependabot CVE: link PR to the security issue, include in relevant milestone

## SAFe Hierarchy (GitHub Issues)

| Level | GitHub object | When to use |
|---|---|---|
| **Milestone** | GitHub Milestone | PI / sprint container, ties to a semver release |
| **Feature** | Issue (`enhancement` label + milestone) | Single deployable unit of value — this is the default issue type |
| **Epic** | Issue (`epic` label, no milestone, task list of linked features) | Only when work spans multiple milestones |
| **Story** | Sub-task within a feature | Only when multiple contributors need independently assignable units |

Default: **milestone → feature**. Add epic and story layers only when the team size and cross-milestone scope justify the overhead.

## Technology Governance

Follow the original developer when a project forks due to governance or ownership breakdown. Validated examples:
- pfSense → **OPNsense** (m0n0wall founder Kasper endorsed it)
- CentOS → **Rocky Linux** (co-founder Kurtzer created it within days)
- nginx → watch **freenginx** (core developer Dounin forked over F5 governance)
- OpenOffice → **LibreOffice** (original developers moved there)

**Avoid:** Oracle (hostile OSS track record), F5/nginx (governance broken), Bitnami (stale images since 2024 paid tier split).

**Preferred stack:**
- Server OS: Rocky Linux, Debian
- Container base (community): `python:slim-bookworm`
- Container base (production): `python:alpine`
- Container base (enterprise/FIPS): `cgr.dev/chainguard/python`
- CNI: Cilium
- Ingress: Kubernetes Gateway API (Cilium native implementation)
- Secrets: HashiCorp Vault sidecar / CSI driver
- Postgres (single node): `postgres:16-alpine` custom subchart
- Postgres (HA): CloudNativePG operator

## ADR Process

ADRs follow an RFC lifecycle: **Draft → Proposed → Accepted / Rejected / Withdrawn**. When a decision changes, a new ADR is created and the old one is marked **Superseded** — the historical record is never deleted.

See `ADR-000-process.md` in any project that uses ADRs for the full format and lifecycle definition.

## Git Commit Style

- Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `refactor:`
- Co-author line on every commit: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
- Commit message: why, not what. The diff shows what; the message explains why.
- Never amend published commits. Create new commits instead.
- Never skip hooks (`--no-verify`) unless explicitly instructed.

## Memory System

Memory lives at: `.claude/projects/<workspace-path>/memory/MEMORY.md`

On starting a new session, read `MEMORY.md` first. It indexes all project-specific memories. Update memory when:
- User corrects an approach or confirms a non-obvious one
- A significant project decision is made
- User preferences or constraints are stated

Never save ephemeral task details to memory — use the todo list for that.
