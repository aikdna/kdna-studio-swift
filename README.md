# KDNA Studio Swift

This source release candidate is a native Creation kernel with the public product `KDNAStudioCore`. It handles ordinary prose and explicit taxonomy, candidate-set and discriminator-set authoring through the same current lifecycle. The exact version and dependency coordinates are in `public-contract-binding.json`.

`Package.swift` compiles `Sources/ComponentCreation` and tests `Tests/ComponentCreationTests`. Previous `Sources/BlankCreation`, earlier sources, tests and evidence remain historical files; they are not compiled into this product. Current evidence uses format 2. There are no compatibility aliases or automatic conversions from previous formats.

## Build and test

SwiftPM resolves KDNACore from the exact public Git revision in `Package.swift`
and `public-contract-binding.json`. A sibling checkout or manually extracted
SDK is no longer required. The retained source archive digest records the SDK
baseline provenance; the Git revision is the installation coordinate. Core is
the native admission implementation, with no AppShared or JavaScript runtime
dependency. Reference Core/Read coordinates do not assert a Read invocation or
permission.

```sh
swift package resolve
python3 scripts/check-source-surface.py --swiftpm
python3 scripts/test_source_surface.py
swift build
swift test
swift build -c release
swift test -c release
python3 scripts/check-public-consumer.py --configuration debug
python3 scripts/check-public-consumer.py --configuration release
```

The separate consumer uses only public imports, actually saves and reopens an
export, checks static/live proof boundaries and verifies that an old API symbol
is unavailable. Its adoption input is synthetic. Use `--work-dir NEW_DIRECTORY`
to retain its build and run logs. The 23 historical files, 15 current fixtures
and four shared contract files have exact inventories; they cannot silently
change or reenter the current compiled target. `surface-disposition.json`
records their status. Original shared contract bytes are retained as pinned
references; their historical acceptance markers do not describe current CI.

## Public authoring lifecycle

`KDNAStudio.createSession(options:adoptionInput:interpretReply:)` returns a `KDNAStudioSession` actor. Options contain `agent: {name, version}` and optional `syntheticFixture: Bool`. `KDNAStudioAdoptionInput(kind:channel:authorization:receive:)` captures an asynchronous input callback. Its kind is `.humanClaimUnverified` or `.delegatedAgentEditorial`; the latter requires the embedding's explicit `{coordinate, statement}` delegation record. These declarations do not authenticate a person, Agent or delegation.

The interpreter receives the actual reply text and the same captured review. Public entry points do not accept a Compiler callback, protocol IDs, asset identity setters or arbitrary runtime modules. The authoring values are documented in [the native API guide](docs/COMPONENT-CREATION.md); the pinned shared contract and its coordinate amendment are in [current-creation](docs/current-creation/CURRENT-CREATION-CONTRACT.md).

1. Use `session.agent.setBrief`, `recordMaterial` and `propose` to record new materials and at least two semantically different alternatives per judgment group.
2. `receiveAdoptionReply()` captures an actual channel message, then interprets it as select, reject, note or confirm. `revise` requires the exact current proposal revision. Select one alternative per group and call `compilePreview()` to inspect the complete pre-Compiler plan.
3. A confirm reply must bind that exact preview. `exportAsset()` consumes the private live context before invoking Compiler. Public Core checks the expected materialization first; a changed Compiler output is rejected even if technically valid.
4. Save the returned bytes, read the actual file again, then call `completeSave(readbackBytes)`. Both success and failure consume the pending save. The library checks captured bytes and fresh Core observations; the embedding owns the actual file operation and its durability.

Three component types, same-type instances, multiple role bindings, unbound components and explicit field absence are preserved. Missing component statements are marked mechanical content representations. An explicit `formationRule.conditions` array becomes the authored overall conditions; comparison criteria are never combined into an invented premise. Only explicitly authored public sources/notices enter the asset. Private source coordinates, raw materials and the private transcript do not enter the three-member container.

## Evidence and limits

`KDNAStudio.verifyCreationEvidence(bytes:evidence:expectedBinding:)` uses actual public Core admission and an independently supplied `{session_id, asset_digest, evidence_digest}` binding. It reconstructs the private history and complete materialization, then compares public Canonical IR across supported providers. A consistent transcript cannot recreate a private live session: static Creation remains `not_evaluated` and live context `unavailable`. Format1, absent or unknown formats, old Core graph coordinates, mixed providers, changed materials and unbound revisions are rejected.

Private JSON hashing uses exact UTF-16 key order, finite binary64 leaf spelling and the common depth-64/100000-value bound. It has no separate array-10000 limit. Asset/session identities are independent lowercase UUIDs, fixed within the session; public IDs follow the owner-qualified shared rule. Compiler artifact `UNKNOWN` and provider fields are bound declarations, not execution identity or signatures.

`accepted_with_live_context` establishes the captured saved-byte expectation within that live process. Identity stays `not_verified`, actions stay `not_evaluated`, and filesystem durability is `not_proven_by_library`. Read permission needs its own trusted host. Synthetic test callbacks are actual fixture executions; they are not actual human or Agent editorial adoption of a domain asset.

SwiftPM declares macOS 13 and iOS 16. CI builds and tests macOS debug/release, runs the separate public consumer, and builds a generic iOS target with code signing disabled. An iOS build is a compilation check, not device runtime, distribution signing or authenticated editorial acceptance.
