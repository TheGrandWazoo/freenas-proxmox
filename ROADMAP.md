# freenas-proxmox / truenas-proxmox — Roadmap

This file captures release scope, business decisions, and deferred items. It is updated in the same commit as any scope or decision change — not just in issues or memory.

---

## Released — v3.0.0 (TrueNAS Custom Plugin)

**Released:** 2026-05-31  
**Branch:** `release/3.x` (default branch)  
**GitHub Release:** https://github.com/TheGrandWazoo/freenas-proxmox/releases/tag/v3.0.0

Full rewrite as a native `PVE::Storage::Custom` plugin. No patching of PVE files, no SSH, full TrueNAS REST API, bearer token auth only.

### Confirmed tested

| Component | Versions |
|-----------|---------|
| Proxmox VE | 8.4.x, 9.2.x |
| TrueNAS CORE | 13.0-U6 |
| TrueNAS SCALE | 24.10 Electric Eel, 25.04, 25.10 |

### What shipped

| # | Fix |
|---|-----|
| [#266](https://github.com/TheGrandWazoo/freenas-proxmox/issues/266) | PVE 9: `lun` string vs integer in QEMU blockdev JSON |
| [#269](https://github.com/TheGrandWazoo/freenas-proxmox/issues/269) | SCALE 25.10 strict Pydantic rejects volsize as string |
| [#267](https://github.com/TheGrandWazoo/freenas-proxmox/issues/267) | free_image 422 on targetextent delete when VM is running |
| [#265](https://github.com/TheGrandWazoo/freenas-proxmox/issues/265) | Loop over all targetextent rows in free_image |
| [#264](https://github.com/TheGrandWazoo/freenas-proxmox/issues/264) | SCALE 25.04 integer type coercion + alias uniqueness |
| [#261](https://github.com/TheGrandWazoo/freenas-proxmox/issues/261) | API token keyfile (`/etc/pve/priv/truenas-<id>.key`) |
| [#262](https://github.com/TheGrandWazoo/freenas-proxmox/issues/262) | Package rename: `freenas-proxmox` → `truenas-proxmox` + transitional package |
| [#263](https://github.com/TheGrandWazoo/freenas-proxmox/issues/263) | Fix `truenas_target` full-IQN match |
| [#260](https://github.com/TheGrandWazoo/freenas-proxmox/issues/260) | TPM state disk limitation callout |
| [#250](https://github.com/TheGrandWazoo/freenas-proxmox/issues/250) | Rollback orphaned TrueNAS resources on `alloc_image` partial failure |
| [#228](https://github.com/TheGrandWazoo/freenas-proxmox/issues/228) | Migration docs: beginner, advanced, troubleshooting |

---

## Released — GitHub Pages APT Repository

**Completed:** 2026-06-06  
**Closed:** [#230](https://github.com/TheGrandWazoo/freenas-proxmox/issues/230)  
**URL:** https://thegrandwazoo.github.io/freenas-proxmox

Replaced Cloudsmith as the primary package distribution channel. Per-major-version dist tracks prevent silent cross-version upgrades (ADR-010). Optional feature packages distributed via apt components (ADR-011).

### Dist tracks

| Dist | Content | Sources.list |
|------|---------|--------------|
| `main` | v2.x — backward-compat alias | `... freenas-proxmox main main` |
| `v2` | v2.x — explicit pin | `... freenas-proxmox v2 main` |
| `v3` | v3.x | `... freenas-proxmox v3 main` |
| `testing` | beta builds | Future — [#272](https://github.com/TheGrandWazoo/freenas-proxmox/issues/272) |

### Components (ADR-011)

| Component | Content |
|-----------|---------|
| `main` | Base plugin (all installs) |
| `multipath` | `truenas-proxmox-multipath` — future opt-in, [#256](https://github.com/TheGrandWazoo/freenas-proxmox/issues/256) |

### Cloudsmith transition state (2026-06-06)

| Channel | State |
|---------|-------|
| Stable (`truenas-proxmox`) | v3.x+ no longer published here; v2.x still published |
| Testing (`truenas-proxmox-testing`) | Still active until #272 ships |

### Migration tooling

`scripts/migrate-repo-to-github-pages.sh` — auto-detects installed version, finds Cloudsmith sources by URL content, switches to correct dist track. Run on each Proxmox node as root.

---

## Deferred Business Decisions

### GitHub Repo Rename: `freenas-proxmox` → `truenas-proxmox`

**Status:** Deferred — no timeline set  
**Decision date:** 2026-05-25  
**Tracked in:** [#229](https://github.com/TheGrandWazoo/freenas-proxmox/issues/229)

All code is ready. GitHub auto-redirects old URLs so there is no technical urgency.

```bash
gh repo rename truenas-proxmox --repo TheGrandWazoo/freenas-proxmox
```

**Note:** `FUNDING.yml` is tied to the user account, not the repo name. Rename has no effect on GitHub Sponsors.

---

## Upcoming — v3.1.0 (PVE 9 + Snapshots)

**Target:** Before PVE 8 EOL — 2026-08-31  
**PVE support:** PVE 9.x only — PVE 8 support dropped  
**Decision date:** 2026-05-31 — see ADR-009  
**Milestone:** [v3.1.0 — PVE 9 + Snapshots](https://github.com/TheGrandWazoo/freenas-proxmox/milestone/4)

v3.1 is the first release that requires PVE 9. Dropping PVE 8 allows:
- Bumping `api()` to PVE 9's `APIVER` (silences "older storage API" warning)
- Implementing snapshot-as-volume-chains (PVE 9 feature)
- Removing the `qemu_blockdev_options` override if Proxmox fixes `Plugin.pm` upstream

### Completed in v3.1.0 (in progress)

| # | Title | Commit |
|---|-------|--------|
| [#270](https://github.com/TheGrandWazoo/freenas-proxmox/issues/270) | Bump `api()` to 14 — silences PVE 9 "older storage API" warning | fc74a42 |
| [#272](https://github.com/TheGrandWazoo/freenas-proxmox/issues/272) | GitHub Pages testing dist track (retires Cloudsmith testing) | 03fe20b |
| [#273](https://github.com/TheGrandWazoo/freenas-proxmox/issues/273) | Debian changelog in package (`apt changelog` was failing) | 1c98591 |
| [#274](https://github.com/TheGrandWazoo/freenas-proxmox/issues/274) | Filename: prefix stripped from Packages — packages not downloadable | 19a3ec2 |
| [#275](https://github.com/TheGrandWazoo/freenas-proxmox/issues/275) | README badges pointed to non-existent repo | da0aaff |
| [#276](https://github.com/TheGrandWazoo/freenas-proxmox/issues/276) | parse_volname state volume crash — RAM snapshots left orphans | 80a7889 |
| [#234](https://github.com/TheGrandWazoo/freenas-proxmox/issues/234) | Snapshot interface — ZFS snapshots via TrueNAS REST API | 59d8a81 |

**Snapshot implementation (2026-06-07):** Verified on PVE 9.2.3 against TrueNAS CORE 13.0-U6 and SCALE 24.10. Disk-only and RAM snapshots both confirmed working end-to-end including rollback.

### Open in v3.1.0

| # | Title | Notes |
|---|-------|-------|
| [#277](https://github.com/TheGrandWazoo/freenas-proxmox/issues/277) | iSCSI GET_LBA_STATUS error on VM start | Log noise, non-fatal |
| [#256](https://github.com/TheGrandWazoo/freenas-proxmox/issues/256) | Multipath — separate plugin (ADR-011) | Hardware-blocked |

| # | Title | Notes |
|---|-------|-------|
| [#234](https://github.com/TheGrandWazoo/freenas-proxmox/issues/234) | Snapshot interface (Snapshot-as-Volume-Chains) | ✅ Done |
| [#270](https://github.com/TheGrandWazoo/freenas-proxmox/issues/270) | Bump `api()` to PVE 9 APIVER | ✅ Done |
| [#272](https://github.com/TheGrandWazoo/freenas-proxmox/issues/272) | GitHub Pages testing dist track (replace Cloudsmith testing) | Required |
| [#256](https://github.com/TheGrandWazoo/freenas-proxmox/issues/256) | Multipath — separate `truenas-proxmox-multipath` plugin (ADR-011) | Blocked on hardware |
| [#249](https://github.com/TheGrandWazoo/freenas-proxmox/issues/249) | Per-variant dispatch (TrueNAS-Core.pm / TrueNAS-Scale.pm) | Evaluate |

### Multipath design decision (2026-06-06)

Multipath ships as a **separate plugin** (`TrueNASMultipath.pm`) in a separate package (`truenas-proxmox-multipath`), distributed via the `multipath` apt component — not as a boolean option in the base plugin. See ADR-011 and [#256](https://github.com/TheGrandWazoo/freenas-proxmox/issues/256).

---

## Upcoming — v4.0.0 (WebSocket API, SCALE 25.x)

**Target:** After PoC testing on SCALE 25.04+  
**Why major version:** WebSocket JSON-RPC 2.0 is a new transport — genuine architectural change.

| # | Title |
|---|-------|
| [#243](https://github.com/TheGrandWazoo/freenas-proxmox/issues/243) | WebSocket JSON-RPC 2.0 API support (TrueNAS SCALE 25.04+) |

---

## Process Rules

- Every business decision (defer, hold, change scope) is recorded here **and** as a comment on the relevant GitHub issue — not only in conversation or AI memory.
- ADRs (in `.claude/cos/adrs/`) capture architectural decisions.
- This file captures timing, business rationale, and deferred actions.
