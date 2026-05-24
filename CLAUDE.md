# freenas-proxmox — Claude Code Guide

## What This Project Is

A native `PVE::Storage::Custom` plugin for Proxmox VE (PVE) that manages TrueNAS ZFS volumes over iSCSI via the TrueNAS REST API. Each VM gets its own dedicated iSCSI target; QEMU drives the connection directly via `iscsi://` paths — no `iscsiadm`, no SSH keys, no patches to PVE core files.

The plugin installs as a Debian package and works by:
1. Copying `TrueNAS.pm` to `/usr/share/perl5/PVE/Storage/Custom/` (auto-discovered by PVE)
2. Copying `truenas-storage.js` to `/usr/share/pve-manager/js/` and injecting one `<script>` tag into `index.html.tpl`

## Repository Layout

```
freenas-proxmox/
├── perl5/PVE/Storage/Custom/TrueNAS.pm   # MAIN plugin — PVE::Storage::Custom subclass
├── ui/truenas-storage.js                  # Proxmox UI panel (storageSchema + input panel)
├── packaging/
│   └── DEBIAN/
│       ├── control.j2    # Package metadata template (VERSION substituted at build time)
│       ├── postinst       # Install: copies .pm + .js, injects <script> tag, restarts PVE
│       └── postrm         # Remove/purge: removes files, strips <script> tag, restarts PVE
└── .github/workflows/
    ├── build.yml          # Active CI: lint → build .deb → security scan → publish
    └── action.yml         # Deprecated no-op (retained so old external links don't 404)
```

## How the Build Works

Everything lives in this repo — there is no external packer repo.

`.github/workflows/build.yml` runs on every push and tag:

| Job | What it does |
|-----|-------------|
| **lint** | `perl -c` syntax check + perlcritic + shellcheck on postinst/postrm |
| **build** | Resolves version from `$VERSION` in `TrueNAS.pm`, assembles `dist/` staging dir, runs `dpkg-deb`, uploads `.deb` as a workflow artifact |
| **security** | Trivy repo scan (secrets + misconfig) + Trivy scan of extracted `.deb` contents |
| **publish** | Pushes `.deb` to Cloudsmith; on `v*.*.*` tags also creates a draft GitHub Release |

### Version / Channel mapping

| Trigger | Version format | Cloudsmith repo |
|---------|---------------|-----------------|
| `v*.*.*` tag | `X.Y.Z-1` | `truenas-proxmox` (stable) |
| `release/3.x` or `master` branch | `X.Y.Z~beta+<sha>` | `truenas-proxmox-testing` |
| other `release/*` branches | `X.Y.Z~alpha+<sha>` | `truenas-proxmox-snapshots` |
| PRs / feature branches | `X.Y.Z~dev+<sha>` | not published |

`$VERSION` in `TrueNAS.pm` is the single source of truth. A version tag that doesn't match emits a CI warning.

## Authentication

- **Bearer Token** (required): `truenas_api_token` — set in PVE storage config

Basic auth (`freenas_user` / `freenas_password`) was removed in v3.0. Bearer token is the only supported mode.

## TrueNAS API

v3.0 uses the TrueNAS v2.0 REST API exclusively. Supported:
- TrueNAS CORE 11.3+ (confirmed tested: CORE 13.0-U6)
- TrueNAS SCALE (confirmed tested: SCALE 24.10 Electric Eel)

## Known Issues / Active Work

- **#228** — v2.x→v3.0 migration: "Move Disk" confirmed working; in-place zvol rename script TBD
- **#234** — Snapshot interface (PVE 9+): not started
- **#243** — WebSocket API (SCALE 25.04+): future
- **#249** — Per-variant dispatch: deferred to v3.1+
- **#250** — alloc_image partial-failure rollback: narrow edge case, open
- **#256** — Multipath support: deferred (no test hardware)
- **#260** — TPM state disks incompatible with `iscsi://` paths: known limitation, store TPM state on local-lvm or NFS

## Key Perl Module

- `PVE::Storage::Custom::TrueNAS` (`perl5/PVE/Storage/Custom/TrueNAS.pm`) — the entire plugin
- Entry points: `alloc_image`, `free_image`, `volume_size_info`, `path`, `activate_volume`, `deactivate_volume`
- API helpers: `_api_call`, `_ensure_target`, `_running_vms_on_storage`

## Packaging / Deployment Notes

- Package name: `freenas-proxmox`
- Apt repos: Cloudsmith (`ksatechnologies/truenas-proxmox` stable, `ksatechnologies/truenas-proxmox-testing` beta)
- Install: `apt install freenas-proxmox` after adding the Cloudsmith repo
- No dpkg triggers — install/remove are handled entirely by `postinst` / `postrm`
- PVE auto-discovers the plugin via `/usr/share/perl5/PVE/Storage/Custom/` on daemon restart

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
