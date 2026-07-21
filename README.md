# KDNA Studio Swift

[![CI](https://github.com/aikdna/kdna-studio-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/aikdna/kdna-studio-swift/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

Native Swift authoring kernel for turning scattered notes, documents, works, and feedback into valid, testable `.kdna` judgment assets — for macOS and iOS apps.

> **Status:** Pre-release Swift authoring component. The published `0.4.0`
> line predates the current Swift Core corrective integration and requires
> exact-coordinate recertification before a stronger compatibility claim.

KDNA Studio Swift is the authoring kernel for Apple platforms. It provides the native primitives for Studio-compatible apps: project model, evidence import, judgment cards, optional provenance, compile, and export. Full Domain-First distillation UI and candidate review live at the app layer; this package is the reusable Swift authoring kernel.

**KDNA Studio Swift is not a UI tool.** It is a pure-logic authoring engine. Humans, agents, tools, and hybrid workflows can create judgment candidates through Studio-compatible authoring paths. Human confirmation and Human Lock are provenance signals for reviewed or high-risk publishing flows, not KDNA format-validity requirements.

A `.kdna` asset is not created by writing JSON files. It is compiled by a
Studio-compatible authoring pipeline that performs validation, canonicalization,
identity generation, digest computation, and provenance recording.

This is the Swift counterpart to [`@aikdna/kdna-studio-core`](https://github.com/aikdna/kdna-studio-core) (JavaScript/npm).

## Apple Ecosystem Pair

| Library | Language | Role |
|---------|----------|------|
| [`kdna-core-swift`](https://github.com/aikdna/kdna-core-swift) | Swift | **Use** KDNA — load, route, inject into LLM |
| **`kdna-studio-swift`** | Swift | **Create** KDNA — author, optionally review/lock, compile, export |

No Node.js dependency and no JavaScriptCore bridge. The package delegates the
runtime wire contract, authorization, and encryption primitives to the
official `kdna-core-swift` package.

## What it does

- **Project Model** — create, load, save, validate Studio projects
- **Judgment Cards** — 7 card types (axiom, boundary, risk, stance, misunderstanding, case, pattern) with 6-state machine
- **Human Lock** — optional provenance for reviewed publishing flows; Studio
  projects may use locked cards to mark confirmed judgment.
- **Authoring Provenance** — exported assets carry Studio-compatible compiler
  metadata, asset/project/build identity, Human Lock count, confirmation status,
  content digest, and project digest.
- **Fingerprint Detection** — SHA256 hash catches post-lock content changes
- **Evidence Import** — text, markdown, interview records
- **Domain-Scoped Authoring Boundary** — one exported `.kdna` should represent one clear judgment domain; multi-asset use requires an explicit, separately admitted Host contract rather than silently broadening or combining files
- **Compiler** — non-deprecated cards → internal KDNA asset entries; review provenance is reported separately
- **Runtime Export** — write a canonical `.kdna` runtime asset; directory export is dev-only

## Runtime Export Contract

`KDNStudioCompiler.compile(_:)` is an authoring compile step. It may produce
source/audit entries such as `KDNA_Core.json`, `KDNA_Patterns.json`, reports,
and build receipts for review.

`KDNStudioCompiler.exportAsset(_:to:project:)` is the user-facing runtime export
step. It must emit only the canonical KDNA runtime container entries:

```text
mimetype
kdna.json
payload.kdnab
checksums.json
```

`payload.kdnab` is CBOR. Password-protected export stores a CBOR encrypted
envelope and can only be consumed after Core returns an authorized LoadPlan;
the normal Agent-facing result is a Runtime Capsule.

The exported manifest uses `format_version: 0.1.0` and identifies the judgment
payload as `kdna.payload.judgment` with `profile_version: 0.1.0`. Encryption,
digest, and Runtime Capsule identifiers name their responsibility; their
independent compatibility coordinates remain numeric semantic versions.

Top-level source entries such as `KDNA_Core.json`, `KDNA_Patterns.json`,
`KDNA_CARD.json`, reports, and `source_cards` are not runtime distribution
entries. Apple Studio apps must use this runtime export path and must not create
app-private `.kdna` envelopes that KDNA Core or CLI cannot inspect.

## Install

Add via Swift Package Manager:

```swift
.package(url: "https://github.com/aikdna/kdna-studio-swift.git", from: "0.4.0")
```

## Quick Start

```swift
import KDNAStudioCore

let manager = KDNStudioProjectManager()

// 1. Create project
var project = manager.createProject(
    name: "writing_judgment",
    author: KDNStudioAuthor(name: "Writing Expert", id: "writer_001")
)

// 2. Create judgment card
var card = KDNStudioCards.createCard(
    type: .axiom,
    fields: [
        "one_sentence": .string("Most writing problems are structural, not language-level."),
        "full_statement": .string("Diagnose structure before language."),
        "why": .string("Surface polishing on weak structure wastes effort."),
        "applies_when": .array(["User asks to review content"]),
        "does_not_apply_when": .array(["User asks for grammar check only"]),
        "failure_risk": .string("May over-diagnose structural problems.")
    ]
)

// 3. Revise. Human Lock is not required for ordinary compile/export.
card = try KDNStudioCards.transitionCard(card, to: .revised, by: "writer_001")
project.cards.append(card)

// 4. Compile and export the canonical runtime .kdna.
let result = try KDNStudioCompiler.compile(project)
let assetURL = try KDNStudioCompiler.exportAsset(result, to: outputURL)

// Optional reviewed-only workflow: record a valid lock, then request the
// explicit policy. A missing, incomplete, or stale recorded lock fails closed.
project.cards[0] = try KDNStudioCards.lockCard(
    project.cards[0],
    by: "writer_001",
    statement: "This represents my professional judgment.",
    appliesWhen: true, doesNotApplyWhen: true, failureRisk: true
)
let reviewedResult = try KDNStudioCompiler.compile(project, requireHumanLock: true)
```

## Card Types

| Type | Compiles to | Description |
|------|------------|-------------|
| `axiom` | KDNA_Core.json | Core judgment principle |
| `ontology` | KDNA_Core.json | Concept boundaries |
| `misunderstanding` | KDNA_Patterns.json | Common wrong interpretation |
| `self_check` | KDNA_Patterns.json | Yes/no verification question |
| `boundary` | KDNA_Core.json | Domain boundary |
| `risk` | KDNA_Core.json | Risk assessment |
| `aesthetic` | KDNA_Core.json | Aesthetic preference |

## Card State Machine

```
draft → revised → locked → tested → published → deprecated
```

Ordinary compilation includes every non-deprecated card. `locked`, `tested`,
and `published` states add review provenance; they are not creation, format, or
ordinary export requirements. Workflows that require reviewed-only output can
call `KDNStudioCompiler.compile(_:requireHumanLock:)` or
`KDNStudioProjectManager.exportProject(_:requireHumanLock:force:forceReason:)`.
Any card that claims Human Lock provenance is validated even in the ordinary
path, so an incomplete or stale lock cannot be exported as a valid claim.

## License

Apache-2.0 — see [LICENSE](LICENSE).
