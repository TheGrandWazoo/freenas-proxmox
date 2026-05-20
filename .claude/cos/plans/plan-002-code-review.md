# Plan 002: Code Review Findings

**Date**: 2026-05-15  
**Reviewed file**: `perl5/PVE/Storage/LunCmd/FreeNAS.pm`  
**Branch**: `feature_bearer_token`

---

## Critical Issues

### 1. Dangling Resources on Failure (ADR-004)

**Location**: `run_create_lu` (~line 265), `run_modify_lu` (~line 183)

`run_create_lu` creates an extent then creates a target-to-extent link. If the second call fails, the extent is left dangling on TrueNAS. Over time these accumulate.

`run_modify_lu` calls `run_delete_lu` then `run_create_lu`. If `run_create_lu` fails, the LUN mapping is gone with no recovery.

**Fix**: eval{} rollback pattern — see ADR-004.

---

### 2. `eval $value` Code Injection Pattern

**Location**: `freenas_iscsi_create_extent` (~line 559) and `freenas_iscsi_create_target_to_extent` (~line 663)

```perl
while ((my $key, my $value) = each %{$freenas_api_methods->{'extent'}->{'post_body'}}) {
    $post_body->{$key} = ($value =~ /^\$.+$/) ? eval $value : $value;
}
```

The `post_body` hash contains strings like `"\$name"` and `"\$device"`. This pattern evaluates them as Perl expressions using local variable names in scope. It works because `$name` and `$device` are in scope, but:
- It's not obvious or maintainable
- A mistake in the API version matrix could silently evaluate unexpected code
- `use strict` would normally catch undeclared variables but `eval` bypasses it

**Fix**: Replace with an explicit substitution map:

```perl
my %substitutions = (
    '$name'      => $name,
    '$device'    => $device,
    '$target_id' => $target_id,
    '$extent_id' => $extent->{'id'},
    '$lun_id'    => $lun_id,
);
while ((my $key, my $value) = each %{$freenas_api_methods->{'extent'}->{'post_body'}}) {
    $post_body->{$key} = exists $substitutions{$value} ? $substitutions{$value} : $value;
}
```

---

### 3. Global Mutable State

**Location**: Top of file (~lines 14-30)

```perl
my $freenas_server_list = undef;
my $freenas_rest_connection = undef;
my $freenas_global_config_list = undef;
my $freenas_global_config = undef;
my $freenas_api_version = "v1.0";
my $freenas_api_methods = undef;
my $freenas_api_variables = undef;
my $runawayprevent = 0;
```

These are module-level globals. `$runawayprevent` is reset to 0 only on successful connection, which means if a connection succeeds then later a separate storage backend is initialized, the counter may not reset properly in some call sequences.

More importantly: `$freenas_rest_connection` and `$freenas_global_config` are pointer variables into the `->{$apihost}` hashes but are also used as direct connection references. This is confusing — sometimes `$freenas_rest_connection` is the connection object, sometimes it's checked as a hash ref.

**Specific bug** in `freenas_api_check` (~line 406):
```perl
if (! defined $freenas_rest_connection->{$apihost}) {
```
`$freenas_rest_connection` is a `REST::Client` object (or undef), not a hash ref. Calling `->{'key'}` on a REST::Client object calls its hash-based accessor (since REST::Client is blessed hashref) — this works by accident but is wrong. The correct check should be `$freenas_server_list->{$apihost}`.

**Fix**: 
- Move `$runawayprevent` to be a local variable passed into `freenas_api_connect` or use a closure
- Fix the `$freenas_rest_connection->{$apihost}` check to `$freenas_server_list->{$apihost}`

---

### 4. Regex Logic Bug in Method Validation

**Location**: `freenas_api_call` (~line 463)

```perl
if (! $method =~ /^(?>GET|DELETE|POST)$/) {
```

This does not do what it looks like. The `!` negates `$method` (making it the empty string `""`), then the empty string is tested against the regex. `""` does NOT match `GET|DELETE|POST`, so `!` of that match is true — meaning the condition is ALWAYS true and the die is always triggered. The code never actually makes an API call!

Wait — actually, let me re-read. In Perl, `!` has lower precedence than `=~`... Actually no. `!` is a unary prefix operator and it binds to `$method`, making it `(!$method)`. `!$method` is the boolean negation of `$method` — which is `""` (false) when `$method` is a non-empty string. Then `"" =~ /^(?>GET|DELETE|POST)$/` is false. Then `!` of that... wait.

Actually: `! $method =~ /regex/` is parsed as `(! $method) =~ /regex/`. 
- `! $method` where `$method = "GET"` is `!1` = `""` (empty string)
- `"" =~ /^(?>GET|DELETE|POST)$/` is FALSE (empty string doesn't match)
- The `if` condition is false, so the die is NOT triggered

So the validation NEVER rejects invalid methods. It should be:
```perl
if ($method !~ /^(?:GET|DELETE|POST)$/) {
```

Also note: `(?>...)` is an atomic group, not a non-capturing group. Use `(?:...)` for non-capturing. In this context (alternation only, no backtracking issue) it doesn't matter, but is misleading.

---

### 5. Silent SSL Verification Disable

**Location**: `freenas_api_connect` (~lines 355-358)

```perl
if ($scfg->{freenas_use_ssl}) {
    $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(verify_hostname => 0);
    $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(SSL_verify_mode => SSL_VERIFY_NONE);
}
```

SSL verification is disabled silently with no user-visible warning. An expired or self-signed cert is a common TrueNAS setup, but users should know they're operating without cert validation.

**Fix**: Log a warning at `syslog("warning", ...)` level when SSL verification is disabled.

---

### 6. Inefficient Multiple API Calls in `freenas_list_lu`

**Location**: `freenas_list_lu` (~line 712)

Every call to `freenas_list_lu` makes 3 API calls: `freenas_iscsi_get_target`, `freenas_iscsi_get_target_to_extent`, `freenas_iscsi_get_extent`. This function is called from:
- `run_list_lu`
- `run_list_extent`
- `run_delete_lu`
- Indirectly from `run_create_lu` via `run_list_lu`

Multiple operations (e.g., `modify_lu` = delete + create) can make 6-9 API calls when 3 would suffice.

**Fix**: Add a per-request cache keyed on `$apihost`. Clear it at the start of each top-level `run_lun_command` call. This is safe because each `run_lun_command` invocation is a complete operation.

---

### 7. API v2.0 `freenas_iscsi_remove_target_to_extent` Early Return

**Location**: `freenas_iscsi_remove_target_to_extent` (~line 692)

```perl
if ($freenas_api_version eq "v2.0") {
    syslog("info", ... "V2.0 API's so NOT Needed...successful");
    return 1;
}
```

This skips the DELETE call for v2.0 APIs entirely, with a comment saying it's "NOT Needed". But the TrueNAS v2.0 API DOES have a `DELETE /api/v2.0/iscsi/targetextent/id/{id}/` endpoint. 

Looking at the `freenas_iscsi_remove_extent` for v2.0, the extent delete body includes `"force": true` — which in TrueNAS v2.0 semantics means "also delete associated targetextents". So this early return is intentional: deleting the extent with `force=true` already removes the targetextent link.

However, this means in `run_delete_lu`, the targetextent link is NOT explicitly removed (it's done implicitly by the force-delete of the extent). The check `$remove_link == 1` at the end of `run_delete_lu` evaluates the return value of `freenas_iscsi_remove_target_to_extent` which returns `1` unconditionally for v2.0 — so the success check still passes.

This is correct behavior but is not obvious. The comment should be improved.

---

### 8. Taint Check Inconsistency

**Location**: `freenas_list_lu` (~line 731) and `ZFSPlugin.pm` patch

```perl
if ($item->{$freenas_api_variables->{'lunid'}} =~ /(\d+)/) {
    ...
    $node->{$freenas_api_variables->{'lunid'}} .= "$1";
```

Taint checking is applied to the lunid but not to other values from the API (extent path, NAA, etc.). If Proxmox VE runs in taint mode, this could cause issues.

**Fix**: Consistently validate all values that come from external API responses before use.

---

### 9. `Custom/FreeNAS.pm` — Duplicate Sub Definitions

**Location**: `perl5/PVE/Storage/Custom/FreeNAS.pm`

The file defines `sub properties` and `sub options` **twice each**. In Perl with `use strict`, this generates a warning ("Subroutine properties redefined"). The second definition wins. The first set of `properties()` and `options()` appears to be for an older/different plugin and was left in by accident.

**Fix**: Remove the first (duplicate) `properties` and `options` subs.

---

## Medium Issues

### 10. Mixed Naming Convention

`freenas_*` vs `truenas_*` is inconsistent. Most internal functions are `freenas_*`. User-facing config variables have both (`freenas_user`, `freenas_password`, `truenas_secret`, `truenas_token_auth`).

**Fix**: In the new `TrueNASPlugin`, use `truenas_*` consistently for all new code.

### 11. `$product_name` Used for TrueNAS SCALE Detection

The `TrueNAS-SCALE` pool name handling:
```perl
if ($product_name eq "TrueNAS-SCALE") {
    $pool =~ s/\//-/g;
}
```
This is a global variable (`my $product_name`) set in `freenas_api_check`. If two different storage backends connect to different TrueNAS instances (one SCALE, one CORE), this global gets overwritten by the last connection. The per-host API version is cached in `$freenas_server_list->{$apihost}` but `$product_name` is not per-host.

**Fix**: Store `product_name` in the per-host hash alongside the connection.

### 12. `REST::Client` vs `LWP::UserAgent`

The file imports both `LWP::UserAgent` and `HTTP::Request` (unused in the current implementation) AND uses `REST::Client`. The imports at the top suggest a migration started but wasn't completed.

**Fix**: In the new plugin, use `LWP::UserAgent` directly and remove the `REST::Client` dependency.

---

## Low / Style Issues

- Several syslog messages still say "FreeNAS::" instead of the caller's actual function
- `&> /dev/null` in postinst swallows errors — use `>> /tmp/freenas-proxmox-install.log 2>&1` instead for debuggability
- Debug `console.warn()` calls left in the pvemanagerlib.js patch (lines 85-89 of the stable-8 patch)

---

## Summary Priority Table

| # | Severity | Issue | Scope |
|---|----------|-------|-------|
| 1 | Critical | Dangling resources on failure | FreeNAS.pm |
| 2 | High | eval $value pattern (unclear, fragile) | FreeNAS.pm |
| 3 | High | Global mutable state / $runawayprevent | FreeNAS.pm |
| 4 | High | Regex bug — method validation never works | FreeNAS.pm |
| 5 | Medium | SSL verify disable without warning | FreeNAS.pm |
| 6 | Medium | Inefficient repeated API calls | FreeNAS.pm |
| 7 | Low | v2.0 targetextent removal comment unclear | FreeNAS.pm |
| 8 | Medium | Taint check inconsistency | FreeNAS.pm |
| 9 | High | Duplicate subs in Custom/FreeNAS.pm | Custom/FreeNAS.pm |
| 10 | Low | Mixed freenas_/truenas_ naming | all |
| 11 | Medium | $product_name not per-host | FreeNAS.pm |
| 12 | Medium | REST::Client vs LWP::UserAgent | FreeNAS.pm |
