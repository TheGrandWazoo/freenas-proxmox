---
name: Bug Report
about: Report a problem with the plugin
title: "[BUG] "
labels: bug
assignees: TheGrandWazoo
---

## Environment

| Component | Version |
|-----------|---------|
| Plugin (`dpkg -l truenas-proxmox freenas-proxmox`) | |
| Proxmox VE (`pveversion`) | |
| TrueNAS type | CORE / SCALE |
| TrueNAS version | |
| Authentication method | Token / Password |

## Description

A clear description of what the bug is.

## Steps to Reproduce

1. 
2. 
3. 

## Expected Behavior

What you expected to happen.

## Actual Behavior

What actually happened.

## Relevant Log Output

Run the following on your Proxmox node and paste the output:

```bash
grep -i freenas /var/log/syslog | tail -50
```

```
(paste log output here)
```

## Storage Configuration

Paste your storage config entry from `/etc/pve/storage.cfg` — **redact any passwords or API tokens**:

```
(paste config here, credentials redacted)
```

## Additional Context

Any other information that might help: network topology, multipath, multiple Proxmox nodes, etc.
