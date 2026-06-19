# KDNA Studio Swift

[![CI](https://github.com/aikdna/kdna-studio-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/aikdna/kdna-studio-swift/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

Native Swift authoring kernel for turning scattered notes, documents, works, and feedback into valid, testable `.kdna` judgment assets — for macOS and iOS apps.

KDNA Studio Swift is the judgment asset refinery for Apple platforms. It provides the native authoring primitives for Studio-compatible apps: project model, evidence import, judgment cards, Human Lock, compile, and export. Full Domain-First distillation UI and candidate review currently live in the KDNA Studio Mac app; this package is the reusable Swift authoring kernel.

**KDNA Studio Swift is not a UI tool.** It is a pure-logic authoring engine. AI can propose judgment candidates. Humans confirm judgment. Only human-locked judgment can be compiled into KDNA.

A `.kdna` asset is not created by writing JSON files. It is compiled by a
Studio-compatible authoring pipeline that performs human confirmation,
validation, canonicalization, identity generation, digest computation, signing,
optional encryption, and provenance recording.

**Hard boundary:** Optional encryption, when supported, MUST be represented as
protected entries inside the `.kdna` container (RFC-0008). App-private encrypted
envelopes or transfer wrappers that cannot be opened by KDNA Core are NOT
conforming KDNA runtime assets.

This is the Swift counterpart to [`@aikdna/kdna-studio-core`](https://github.com/aikdna/kdna-studio-core) (JavaScript/npm).

## Apple Ecosystem Pair

| Library | Language | Role |
|---------|----------|------|
| [`kdna-core-swift`](https://github.com/aikdna/kdna-core-swift) | Swift | **Use** KDNA — load, route, inject into LLM |
| **`kdna-studio-swift`** | Swift | **Create** KDNA — author, lock, compile, export |

No Node.js dependency. No JavaScriptCore bridge. Pure Swift, zero external dependencies.

## What it does

- **Project Model** — create, load, save, validate Studio projects
- **Judgment Cards** — 9 card types with 6-state machine
- **Human Lock** — AI proposes, human confirms. Only locked cards compile.
- **Authoring Provenance** — exported assets carry Studio-compatible compiler
  metadata, asset/project/build identity, Human Lock count, confirmation status,
  content digest, and project digest.
- **Fingerprint Detection** — SHA256 hash catches post-lock content changes
- **Evidence Import** — text, markdown, interview records
- **Domain-Scoped Authoring Boundary** — one exported `.kdna` should represent one clear judgment domain; complex work should compose multiple assets through KDNA Clusters rather than broadening a single file
- **Compiler** — locked cards → internal KDNA asset entries
- **Runtime Export** — write a canonical KDNA Core v1 `.kdna` runtime asset; directory export is dev-only

## Runtime Export Contract

`KDNStudioCompiler.compile(_:)` is an authoring compile step. It may produce
source/audit entries such as `KDNA_Core.json`, `KDNA_Patterns.json`, reports,
and build receipts for review.

`KDNStudioCompiler.exportAsset(_:to:project:)` is the user-facing runtime export
step. It must emit only the canonical KDNA Core v1 runtime container entries:

```text
mimetype
kdna.json
payload.kdnab
checksums.json
```

Top-level source entries such as `KDNA_Core.json`, `KDNA_Patterns.json`,
`KDNA_CARD.json`, reports, and `source_cards` are not runtime distribution
entries. Apple Studio apps must use this runtime export path and must not create
app-private `.kdna` envelopes that KDNA Core, CLI, or Chat cannot inspect.

## Install

Add via Swift Package Manager:

```swift
.package(url: "https://github.com/aikdna/kdna-studio-swift.git", from: "0.1.0")
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

// 3. Revise, then Human Lock
card = try KDNStudioCards.transitionCard(card, to: .revised, by: "writer_001")
card = try KDNStudioCards.lockCard(card,
    by: "writer_001",
    statement: "This represents my professional judgment.",
    appliesWhen: true, doesNotApplyWhen: true, failureRisk: true
)
project.cards.append(card)

// 4. Check gate
let gate = KDNStudioHumanLockGate.check(project)
if !gate.blocked {
    // 5. Compile
    let result = try KDNStudioCompiler.compile(project)
    // 6. Export canonical runtime .kdna
    let assetURL = try KDNStudioCompiler.exportAsset(result, to: outputURL)
}
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

Only `locked`, `tested`, or `published` cards can be compiled.

## License

Apache-2.0 — see [LICENSE](LICENSE).
