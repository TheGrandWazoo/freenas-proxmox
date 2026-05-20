# Architecture Decision Records

ADRs document significant decisions made about this project. They follow an RFC-style lifecycle.

## Lifecycle

| Status | Meaning |
|--------|---------|
| **Draft** | Being written or discussed. Not yet binding. May change freely. |
| **Accepted** | Agreed upon and in effect. Guides implementation. |
| **Superseded** | Replaced by a newer ADR. The old record is preserved as history. The header notes which ADR supersedes it. |
| **Rejected** | Proposed but explicitly decided against. Preserved so we remember why. |
| **Deprecated** | Was accepted but no longer applicable (e.g., a feature was dropped). Not replaced. |

## Rules

- **Never edit the Decision section of an Accepted ADR.** If the decision changes, write a new ADR and mark the old one `Superseded by ADR-XXX`.
- **Draft ADRs can be edited freely** — they are working documents.
- **Numbering is sequential and permanent.** A superseded ADR keeps its number; the new one gets the next number.
- **Context and Consequences sections** may be lightly edited for clarity even after acceptance (fix typos, add links), but the decision itself is immutable.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-consolidate-build-into-main-repo.md) | Consolidate Build Pipeline into Main Repo | Accepted |
| [ADR-002](ADR-002-ui-strategy.md) | UI Integration Strategy | Accepted |
| [ADR-003](ADR-003-apt-repo-hosting.md) | APT Repository Hosting | Accepted |
| [ADR-004](ADR-004-cleanup-on-failure.md) | Transactional Cleanup on API Operation Failure | Accepted |
| [ADR-005](ADR-005-bearer-token-authentication.md) | Bearer Token Authentication as Primary Auth Method | Accepted |
| [ADR-006](ADR-006-versioning-strategy.md) | Package Versioning Strategy | Accepted |
| [ADR-007](ADR-007-freenas-vs-truenas-naming.md) | FreeNAS vs TrueNAS Module Naming | Accepted |
