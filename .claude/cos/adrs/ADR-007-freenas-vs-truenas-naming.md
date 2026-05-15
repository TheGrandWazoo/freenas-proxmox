# ADR-007: FreeNAS vs TrueNAS Module Naming

**Date**: 2026-05-15  
**Status**: Decided  
**Deciders**: Kevin Adams

## Context

The Perl module is named `FreeNAS.pm` and installs to `PVE::Storage::LunCmd::FreeNAS`. The `iscsiprovider` value stored in Proxmox VE's `/etc/pve/storage.cfg` is `freenas`. All existing user configurations reference this name.

The product was renamed from FreeNAS to TrueNAS in 2020. The package is in the process of being modernized (v3.x goal is `PVE::Storage::Custom::TrueNASPlugin`).

## Decision

**v2.x (current):** Keep `FreeNAS.pm` and `iscsiprovider freenas`.

Changing the filename or the `iscsiprovider` value in v2.x would silently break every existing user's storage configuration — Proxmox would fail to load the backend, and VMs with attached storage would become inaccessible. The backward-compat cost is too high for a minor release.

**v3.x (new Custom plugin):** Use `TrueNAS.pm` (or embed in `TrueNASPlugin.pm`) and `type truenas`.

The v3.x architecture introduces a new storage type (`truenas`) via `PVE::Storage::Custom::TrueNASPlugin`. This is a clean break — users explicitly create a new `truenas`-type storage and migrate their VMs. The old `freenas` iSCSI provider continues to work in parallel during the transition.

## Migration Path

When v3.x ships:
1. Users create a new `truenas`-type storage pointing at the same TrueNAS server
2. Migrate VMs from old `freenas`-provider storage to new `truenas` storage using `qm move-disk` / `pvesm` commands
3. Remove the old `freenas`-provider storage definition
4. The v3.x `postrm` removes `FreeNAS.pm` and reverses ZFSPlugin patches; the v2.x files are no longer needed

## Internal Variable Naming

Within `FreeNAS.pm` (v2.x): continue using `freenas_*` variable names — changing them mid-v2.x would be a pointless churn commit with no user benefit.

Within the new `TrueNASPlugin.pm` (v3.x): use `truenas_*` for all new variables. New user-facing config keys should be `truenas_*`. Existing `freenas_*` keys are mapped as aliases for backward compat during the transition window.
