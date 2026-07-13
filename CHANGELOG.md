# Changelog

## 0.3.0 (2026-07-13)
- Export the single KDNA runtime container with CBOR `payload.kdnab`
- Encode password-protected envelopes as CBOR and keep decrypted content in memory
- Align runtime manifest, load profiles, and checksums with the JavaScript Studio Core
- Verify public and password-protected exports through Swift Core Runtime Capsules
- Remove legacy distribution-manifest vocabulary from generated authoring metadata

## 0.2.0 (2026-05-30)
- KDNStudioProvenance: provenance-report.json generation
- KDNStudioQuality: quality gates with source_mode trust differentiation
- KDNStudioGovernance: KDNA_CARD.json generation
- Compiler: KDNA_Scenarios/Cases/Reasoning/Evolution, 6 report files
- Export verification: runtime cross-check using KDNACore

## 0.1.0 (2026-05-25)
- Initial release: project model, cards, compiler, export, human lock gate
