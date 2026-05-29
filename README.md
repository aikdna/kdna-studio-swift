# KDNA Studio Swift

Native Swift authoring kernel for turning human judgment into valid, testable `.kdna` cognition assets — for macOS and iOS apps.

This is the foundation for native Apple apps that create and manage personal or professional KDNA cognitive assets locally.

**KDNA Studio Swift is not a UI tool.** It is a pure-logic authoring engine. AI can propose judgment candidates. Humans confirm judgment. Only human-locked judgment can be compiled into KDNA.

This is the Swift counterpart to [`@aikdna/kdna-studio`](https://github.com/aikdna/kdna-studio-core) (JavaScript/npm).

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
  metadata, Human Lock count, confirmation status, and project digest.
- **Fingerprint Detection** — SHA256 hash catches post-lock content changes
- **Evidence Import** — text, markdown, interview records
- **Compiler** — locked cards → internal KDNA asset entries
- **Export** — write a canonical `.kdna` asset; directory export is dev-only

## Install

Add via Swift Package Manager:

```swift
.package(url: "https://github.com/aikdna/kdna-studio-swift.git", from: "0.1.0")
```

## Quick Start

```swift
import KDNaStudioCore

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
