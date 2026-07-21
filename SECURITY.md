# Security Policy

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use one of these private channels:

- **GitHub Private Vulnerability Reporting**: Go to the [Security Advisories](https://github.com/aikdna/kdna-studio-swift/security/advisories/new) page
- **Email**: security@aikdna.com

We aim to respond within 72 hours and provide a timeline for resolution within
1 week. Please do not disclose the vulnerability publicly until we have had a
chance to address it.

## Supported Versions

`kdna-studio-swift` is a public pre-release support surface for Apple-platform
authoring kernels.

| Component | Supported Versions |
|-----------|-------------------|
| KDNA Protocol | Latest tagged release in `aikdna/kdna` |
| kdna-studio-swift | Latest mainline pre-release |
| kdna-core-swift | Latest mainline pre-release |

Older Swift pre-release versions may receive critical security patches on a
case-by-case basis.

## Security Model

`kdna-studio-swift` is an authoring kernel. It must not define runtime
authorization, entitlement, or crypto policy; exported runtime assets must
remain inspectable by KDNA Core and the official CLI.

For the KDNA Protocol security architecture, see
[GOVERNANCE.md](https://github.com/aikdna/kdna/blob/main/docs/GOVERNANCE.md)
in the main protocol repository.
