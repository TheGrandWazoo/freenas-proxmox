# Contributing to truenas-proxmox

Thank you for your interest in contributing. This document covers how to report bugs, request features, and submit code.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)
- [Development Setup](#development-setup)
- [Submitting Changes](#submitting-changes)
- [Coding Standards](#coding-standards)
- [Branch Strategy](#branch-strategy)

---

## Code of Conduct

Be respectful. This is a community project maintained in spare time. Constructive criticism is welcome; hostility is not.

---

## Reporting Bugs

Use the [bug report issue template](https://github.com/TheGrandWazoo/truenas-proxmox/issues/new?template=bug_report.md).

Before filing:
- Check existing [open and closed issues](https://github.com/TheGrandWazoo/truenas-proxmox/issues?q=is%3Aissue) for duplicates
- Reproduce the issue on the latest release if possible

**Always include:**
- Proxmox VE version (`proxmox-ve` package version)
- TrueNAS version and type (CORE / SCALE)
- Plugin version (`dpkg -l truenas-proxmox`)
- Relevant log lines from syslog (`grep -i freenas /var/log/syslog`)
- The storage configuration (redact passwords/tokens)

---

## Requesting Features

Use the [feature request issue template](https://github.com/TheGrandWazoo/truenas-proxmox/issues/new?template=feature_request.md).

Feature requests are evaluated against the project roadmap. Large changes should be discussed in an issue before a pull request is opened.

---

## Development Setup

### What You Need

- A Proxmox VE node (physical or VM) — version 8.x recommended
- A TrueNAS instance (CORE or SCALE) accessible from the Proxmox node
- Basic Perl knowledge
- `dpkg-deb` for building packages locally

### Local Build

```bash
git clone https://github.com/TheGrandWazoo/truenas-proxmox.git
cd truenas-proxmox

# Build the package (once packaging/ directory exists in v3.x)
dpkg-deb -Zgzip --build packaging truenas-proxmox_dev_all.deb

# Install locally for testing
dpkg -i truenas-proxmox_dev_all.deb
```

### Testing Changes to FreeNAS.pm

You can copy the Perl module directly to the Proxmox node for quick iteration without rebuilding the package:

```bash
scp perl5/PVE/Storage/LunCmd/FreeNAS.pm \
    root@your-proxmox-node:/usr/share/perl5/PVE/Storage/LunCmd/FreeNAS.pm

# Restart PVE services on the node
ssh root@your-proxmox-node "pvedaemon restart && pveproxy restart"
```

### Checking Perl Syntax

```bash
perl -c perl5/PVE/Storage/LunCmd/FreeNAS.pm
perl -c perl5/PVE/Storage/Custom/TrueNASPlugin.pm
```

---

## Submitting Changes

1. Fork the repository
2. Create a branch from `master`: `git checkout -b feature/your-description`
3. Make your changes — see [Coding Standards](#coding-standards)
4. Test on a real Proxmox + TrueNAS setup if possible
5. Open a pull request against `master`

Pull requests should:
- Have a clear description of what changed and why
- Reference any related issues (`Fixes #123`)
- Not include unrelated changes

---

## Coding Standards

### Perl

- `use strict` and `use warnings` in all modules
- Use `syslog("info", ...)` for normal operation logging, `syslog("err", ...)` for errors
- Include the caller context in log lines: `(caller(0))[3] . " : message"`
- All external API calls wrapped in error handling with cleanup on failure
- No `eval $variable` patterns — use explicit substitution maps
- Prefer `LWP::UserAgent` over `REST::Client` for new code

### Shell (postinst/postrm)

- `set -e` at the top of all scripts
- Log to a file rather than swallowing output with `&> /dev/null`
- Use shellcheck-clean scripts (`shellcheck packaging/DEBIAN/postinst`)
- Idempotent operations — scripts must be safe to run multiple times

### Patches

- Patches live in `stable-N/` directories where N is the Proxmox VE major version
- Always include both `.orig` and `.patch` for reference
- Test with `patch --dry-run` before committing
- Use `--ignore-whitespace` in patch commands

---

## Branch Strategy

| Branch | Purpose | Builds to |
|--------|---------|-----------|
| `master` | Main development branch | Beta/testing apt channel |
| `feature/*` | Feature branches | Alpha apt channel |
| `stable` / tagged releases | Release-ready code | Stable apt channel |

Tag releases as `vMAJOR.MINOR.PATCH` (e.g., `v3.0.0`).
