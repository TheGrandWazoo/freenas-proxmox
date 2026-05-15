# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 3.x (upcoming) | Yes |
| 2.3.x | Yes |
| 2.2.x and earlier | No — please upgrade |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email security reports to: **security@ksatechnologies.com** (or **theprofessor@ksatechnologies.com**)

Include:
- A description of the vulnerability
- Steps to reproduce
- The potential impact
- Any suggested fixes if you have them

You will receive an acknowledgment within 72 hours. We aim to release a fix within 14 days for confirmed vulnerabilities and will credit reporters in the release notes unless anonymity is requested.

## Security Considerations for Operators

- **API tokens are stored in `/etc/pve/storage.cfg`** which is readable only by root and replicated across the PVE cluster via `pmxcfs`. Treat cluster access accordingly.
- **Use API token authentication** rather than username/password. Tokens can be revoked individually without changing your TrueNAS user password.
- **Enable SSL** on the TrueNAS API connection. The plugin accepts self-signed certificates (SSL verification is relaxed) — use a private CA or valid certificate where possible.
- **Scope API tokens** to the minimum required permissions on TrueNAS if your version supports scoped tokens.
- **Restrict network access** to the TrueNAS management interface to only the Proxmox nodes that need it.
