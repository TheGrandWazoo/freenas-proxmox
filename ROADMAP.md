# freenas-proxmox / truenas-proxmox — Roadmap

This file captures release scope, business decisions, and deferred items. It is updated in the same commit as any scope or decision change — not just in issues or memory.

---

## Current Release — v3.0.0 (TrueNAS Custom Plugin)

**Branch:** `release/3.x`  
**Status:** Code complete — blocked on #266 (PVE 9 VM start failure) before tagging  
**Target:** Ship before PVE 8 EOL (2026-08-31)

Full rewrite as a native `PVE::Storage::Custom` plugin. No patching of PVE files, no SSH, full TrueNAS REST API, bearer token auth only.

### Blocking — must fix before v3.0.0 tag

None. All blocking issues resolved.

### Pre-release housekeeping (non-blocking, do before tag)

| Task | Status |
|------|--------|
| Write ADR-009 superseding ADR-008 — PVE 9 support confirmed, fix approach, snapshot deferred | Pending |
| Close epic #219 | Pending |
| File issue for "older storage API" warning — api() version bump for PVE 9 | Pending |

### Lab upgrade plan (required to test #266)

| Node | Current | Target | Notes |
|------|---------|--------|-------|
| pve01-hq | PVE 8.4.19 | PVE 9.x | Blocked: Ceph Quincy → Reef first; systemd-boot pkg remove |
| pve02-hq | PVE 8.4.14 | PVE 9.x (possible) | TBD |
| pve03-hq | PVE 8.3.2 | Stay 8.4 | Regression baseline |
| pve04-hq | PVE 8.3.2 | Stay 8.4 | Regression baseline |

Ceph upgrade (Quincy → Reef) must complete across all 4 nodes before pve01 OS upgrade.

### Completed in v3.0.0

| # | Title | Commit |
|---|-------|--------|
| [#266](https://github.com/TheGrandWazoo/freenas-proxmox/issues/266) | PVE 9: VM fails to start — `lun` string vs integer in QEMU blockdev JSON | pending commit |
| [#269](https://github.com/TheGrandWazoo/freenas-proxmox/issues/269) | SCALE 25.10 strict Pydantic rejects volsize as string | `c7ce39d` |
| [#267](https://github.com/TheGrandWazoo/freenas-proxmox/issues/267) | free_image 422 on targetextent delete when VM is running | `359c2af` |
| [#265](https://github.com/TheGrandWazoo/freenas-proxmox/issues/265) | Loop over all targetextent rows in free_image | `0dea6bc` |
| [#264](https://github.com/TheGrandWazoo/freenas-proxmox/issues/264) | SCALE 25.04 compatibility: integer type coercion + alias uniqueness | `96957c0` |
| [#261](https://github.com/TheGrandWazoo/freenas-proxmox/issues/261) | API token keyfile (`/etc/pve/priv/truenas-<id>.key`) | `f30862f` |
| [#262](https://github.com/TheGrandWazoo/freenas-proxmox/issues/262) | Package rename: `freenas-proxmox` → `truenas-proxmox` (transitional package ships) | `9b2ecb8` |
| [#263](https://github.com/TheGrandWazoo/freenas-proxmox/issues/263) | Fix `truenas_target` full-IQN match | `3a8a5df` |
| [#260](https://github.com/TheGrandWazoo/freenas-proxmox/issues/260) | TPM state disk limitation callout in README | `0a8e7e7` |
| [#250](https://github.com/TheGrandWazoo/freenas-proxmox/issues/250) | Rollback orphaned TrueNAS resources on `alloc_image` partial failure | `eab964c` |
| [#228](https://github.com/TheGrandWazoo/freenas-proxmox/issues/228) | Migration path v2.x→v3.x docs (beginner, advanced, troubleshooting) | `0a17a30` |
| [#252](https://github.com/TheGrandWazoo/freenas-proxmox/issues/252) | Integration test 2.x→3.0 upgrade path | closed |

---

## Deferred Business Decisions

### GitHub Repo Rename: `freenas-proxmox` → `truenas-proxmox`

**Status:** Deferred — no timeline set  
**Decision date:** 2026-05-25  
**Tracked in:** [#262](https://github.com/TheGrandWazoo/freenas-proxmox/issues/262) (comment)

All code is ready: the `truenas-proxmox` package is built and published; the transitional `freenas-proxmox` package is in place. GitHub URLs in docs are already updated to the new name.

The actual `gh repo rename` on GitHub has been deliberately held. This is a business-timing decision — GitHub redirects old URLs automatically so there is no technical urgency. The rename can be done at any time by running:

```bash
gh repo rename truenas-proxmox --repo TheGrandWazoo/freenas-proxmox
```

**Note:** `FUNDING.yml` contains only `github: TheGrandWazoo` (tied to the user account, not the repo). The rename has **no effect** on GitHub Sponsors.

---

## Upcoming — v3.1.0 (Snapshots + PVE 9 hardening)

**Target:** Before PVE 8 EOL — 2026-08-31

| # | Title |
|---|-------|
| [#234](https://github.com/TheGrandWazoo/freenas-proxmox/issues/234) | Snapshot interface (Snapshot-as-Volume-Chains, PVE 9.0+) |
| [#249](https://github.com/TheGrandWazoo/freenas-proxmox/issues/249) | Per-variant dispatch (TrueNAS-Core.pm / TrueNAS-Scale.pm) — evaluate |
| [#256](https://github.com/TheGrandWazoo/freenas-proxmox/issues/256) | Multipath support |

---

## Upcoming — v3.2.0 (WebSocket API, SCALE 25.x)

**Target:** After PoC testing on SCALE 25.04 Fangtooth and 25.10 Goldeye  
**Scope:** TBD pending PoC results

| # | Title |
|---|-------|
| [#243](https://github.com/TheGrandWazoo/freenas-proxmox/issues/243) | WebSocket JSON-RPC 2.0 API support (TrueNAS SCALE 25.04+) |

**Lab note:** A TrueNAS SCALE 25.04 node is available for PoC testing (stood up 2026-05-25, minimal config).

---

## Process Rules

- Every business decision (defer, hold, change scope) is recorded here **and** as a comment on the relevant GitHub issue — not only in conversation or AI memory.
- ADRs (in `.claude/cos/adrs/`) capture architectural decisions.
- This file captures timing, business rationale, and deferred actions.
