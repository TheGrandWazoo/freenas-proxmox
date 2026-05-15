# ADR-004: Transactional Cleanup on API Operation Failure

**Date**: 2026-05-15  
**Status**: Decided  
**Deciders**: Kevin Adams

## Context

When `run_create_lu` partially succeeds — it creates an iSCSI extent on TrueNAS but then fails to create the target-to-extent mapping — the extent remains on TrueNAS with no association. These "dangling" extents accumulate and cause problems (LUN ID exhaustion, confusion in TrueNAS UI, wasted pool space).

Similarly, if `run_delete_lu` fails partway through, things can be left in a partial state.

## Current Code Path (broken)

```perl
sub run_create_lu {
    my $extent = freenas_iscsi_create_extent($scfg, $lun_path);   # Step 1
    my $link = freenas_iscsi_create_target_to_extent(              # Step 2
        $scfg, $target_id, $extent->{'id'}, $lun_id);
    die "Unable to create lun" if !defined($link);                 # Too late — extent already exists
}
```

If Step 2 fails, the code dies but the extent from Step 1 is still on TrueNAS.

## Decision

Implement try/catch rollback using `eval {}` blocks. On failure, undo completed steps in reverse order before dying.

## Pattern

```perl
sub run_create_lu {
    my $extent = freenas_iscsi_create_extent($scfg, $lun_path);
    die "Unable to create extent" unless defined $extent;

    my $link = eval { freenas_iscsi_create_target_to_extent(
        $scfg, $target_id, $extent->{'id'}, $lun_id) };
    if (!defined($link) || $@) {
        my $err = $@ || "target-to-extent creation returned undef";
        syslog("err", (caller(0))[3] . " : rolling back extent $extent->{'id'}: $err");
        eval { freenas_iscsi_remove_extent($scfg, $extent->{'id'}) };
        syslog("err", (caller(0))[3] . " : rollback cleanup failed: $@") if $@;
        die "Unable to create lun $lun_path (extent cleaned up): $err";
    }
}
```

## Scope of Changes

All multi-step operations need this pattern:

| Operation | Steps | Rollback needed |
|-----------|-------|-----------------|
| `run_create_lu` | create extent → create targetextent | if targetextent fails, delete extent |
| `run_delete_lu` | find link → remove extent → remove targetextent | if either remove fails, log but don't re-add (partial delete is better than no delete) |
| `run_modify_lu` | delete old LU → create new LU | if create fails, the old LU is gone — log clearly and die |

For `modify_lu` specifically: the current code deletes then creates. If the create fails, data is not lost (the zvol is still there) but the iSCSI mapping is gone. We should create the new extent first, then delete the old link, then add the new link.

## Logging

All rollback actions should be logged at `syslog("err", ...)` level with enough context to manually recover: extent ID, target ID, LUN ID.
