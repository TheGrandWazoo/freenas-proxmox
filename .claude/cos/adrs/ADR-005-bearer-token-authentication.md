# ADR-005: Bearer Token Authentication as Primary Auth Method

**Date**: 2026-05-15  
**Status**: Accepted  
**Deciders**: Kevin Adams

## Context

TrueNAS SCALE and recent TrueNAS CORE versions support API key (Bearer Token) authentication. Basic auth (username + password) requires a full system user account, is less secure, and may be deprecated in future TrueNAS releases.

The `feature_bearer_token` branch already has partial support:
- `truenas_token_auth` flag (boolean)
- `truenas_secret` field (holds either password or token depending on flag)
- Bearer Token header set in `freenas_api_connect` when flag is true

## Decision

Bearer Token auth should be the **primary** and recommended authentication method. Basic auth remains for backward compatibility.

## Changes Required

### In `LunCmd/FreeNAS.pm` (and future `Custom/TrueNASPlugin.pm`)

1. **Token auth is default** when `truenas_token_auth` is not explicitly set (or default to requiring it in new plugin)
2. **Validation at startup**: in `run_lun_command`, validate credentials presence before any API call
3. **Error messages** should guide users toward token auth when credentials are missing

### In the UI (Custom Plugin properties)

The new custom storage plugin defines these properties:
```perl
truenas_token_auth => {
    description => "Use API Token instead of username/password",
    type => 'boolean',
    default => 1,  # Default to token auth in the new plugin
},
truenas_secret => {
    description => "TrueNAS API Token or Password",
    type => 'string',
},
freenas_user => {
    description => "TrueNAS Username (only needed without token auth)",
    type => 'string',
    optional => 1,
},
```

PVE auto-generates the UI form — the `freenas_user` field would be conditionally hidden in the UI when `truenas_token_auth` is true. This hiding behavior in the auto-generated form may need to be tested against PVE 8.x's form rendering.

### Generating an API Token in TrueNAS

TrueNAS SCALE: System → API Keys → Add  
TrueNAS CORE: This may require web UI access or direct CLI.

The token is a long random string; it goes in the `truenas_secret` field. No username needed with token auth.

## Backward Compatibility

- Existing configs using `freenas_password` + `freenas_user` continue to work
- The custom plugin should map legacy fields on first load
- `freenas_password` is aliased to `truenas_secret` for backward compat

## Security Notes

- Tokens should be scoped to minimum needed permissions if TrueNAS supports scoped tokens
- The secret is stored in `/etc/pve/storage.cfg` (PVE cluster config) — it is not encrypted but the file is only readable by root
