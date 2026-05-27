# freenas-proxmox / truenas-proxmox — Roadmap

This file captures release scope, business decisions, and deferred items. It is updated in the same commit as any scope or decision change — not just in issues or memory.

---

## Current Release — v3.0.0 (TrueNAS Custom Plugin)

**Branch:** `release/3.x`  
**Target:** Ship before PVE 8 EOL (2026-08-31)

Full rewrite as a native `PVE::Storage::Custom` plugin. No patching of PVE files, no SSH, full TrueNAS REST API, bearer token auth only.

### Remaining open items

| # | Title | Type |
|---|-------|------|
| [#228](https://github.com/TheGrandWazoo/freenas-proxmox/issues/228) | Migration path v2.x→v3.x docs | docs |
| [#252](https://github.com/TheGrandWazoo/freenas-proxmox/issues/252) | Integration test 2.x→3.0 upgrade path docs | docs |

### Completed in v3.0.0

| # | Title | Commit |
|---|-------|--------|
| [#261](https://github.com/TheGrandWazoo/freenas-proxmox/issues/261) | API token keyfile (`/etc/pve/priv/truenas-<id>.key`) | `f30862f` |
| [#262](https://github.com/TheGrandWazoo/freenas-proxmox/issues/262) | Package rename: `freenas-proxmox` → `truenas-proxmox` (transitional package ships) | `9b2ecb8` |
| [#263](https://github.com/TheGrandWazoo/freenas-proxmox/issues/263) | Fix `truenas_target` full-IQN match | `3a8a5df` |
| [#260](https://github.com/TheGrandWazoo/freenas-proxmox/issues/260) | TPM state disk limitation callout in README | `0a8e7e7` |
| [#264](https://github.com/TheGrandWazoo/freenas-proxmox/issues/264) | SCALE 25.04 compatibility: integer type coercion + alias uniqueness | `96957c0` |
| [#250](https://github.com/TheGrandWazoo/freenas-proxmox/issues/250) | Rollback orphaned TrueNAS resources on `alloc_image` partial failure | `eab964c` |

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

## Upcoming — v3.1.0 (PVE 9 + Snapshots)

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
