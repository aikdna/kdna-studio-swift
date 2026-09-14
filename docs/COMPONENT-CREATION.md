# Native public Creation API

The executable product is `KDNAStudioCore`. All JSON records use public `KDNAValue`; no protocol parser is added by Studio. The shared authoring schema is [API.d.ts](current-creation/API.d.ts); its field shapes apply to the Swift values below. The [schema identity amendment](current-creation/SCHEMA-IDENTITY-DEPENDENCY-AMENDMENT.json) supersedes the original contract's RC1 dependency spelling with exact RC2 coordinates.

```swift
let session = try KDNAStudio.createSession(
    options: ["agent": ["name": "embedding-agent", "version": "1"]],
    adoptionInput: KDNAStudioAdoptionInput(
        kind: .delegatedAgentEditorial,
        channel: "embedding-editorial-input",
        authorization: ["coordinate": "recorded-delegation-coordinate",
                        "statement": "The embedding records its actual delegated scope here."],
        receive: { review in /* obtain an actual bound input message */
            throw EmbeddingError.inputUnavailable
        }),
    interpretReply: { text, review in /* interpret the actual message */
        throw EmbeddingError.inputUnavailable
    })
```

The callback bodies and `EmbeddingError` above are embedding placeholders, not a synthetic confirmation. A message is `{id, role, channel, review_id, text}`. The captured review supplies its session/revision/channel/groups and optional exact preview. `role` is `human` for `.humanClaimUnverified` and `agent` for `.delegatedAgentEditorial`. The interpreter returns `{kind: "select", choices: [{judgmentLocalKey, alternativeLocalKey}]}` or `{kind: "confirm" | "reject" | "note"}`. Each actual message ID is one-use, including failed interpretation. During asynchronous callbacks, mutations reject as busy; abort invalidates the in-flight result.

The `session.agent` methods are:

- `setBrief({title, scope})`.
- `recordMaterial({kind: "text" | "interview", title, content, coordinate})`, returning the immutable recorded material with generated ID, content digest and call timestamp.
- `propose({localKey, alternatives})`, where each alternative has `{localKey, title, subject, scope, statement, rationale, materialRefs}`. At least two different semantic alternatives are required. Changing only local key, title, rationale or private material references does not create a different semantic alternative.
- `revise(localKey, {baseRevision, alternatives, explanation})`, replacing one exact current proposal and retaining its history.
- `compilePreview()`, requiring a brief, actual materials, groups and a current complete selection.

An optional alternative `method` is `{method: {term, extension?}, components?, bindings?}`. `method` is required inside that record. Absent `components` or `bindings` differs from a present empty array; null is not an absence marker. Each component is `{localKey, type, content, statement?}`. Taxonomy content has `{items, broader}` with edges `{narrowerKey, broaderKey}`; candidate-set content has `{items}`; discriminator-set content has `{candidateSetLocalKey, items}` and contrasts `{candidateKey, criterion}`. References are resolved within the owning judgment, even when two owners use the same local key. Components of one type may coexist; bindings `{componentLocalKey, role}` may assign multiple roles. Shared Core remains the sole content interpreter and graph/budget validator.

`formationRule: {conditions: [{kind: "interpreted", statement}]}` is explicit authorship, including an explicit empty conditions array. Its presence removes the ordinary fixed text result. `publicSources` and `publicNotices` follow the exact shared API and expose only information the author chose to publish. Stable native IDs follow [the identity specification](current-creation/ASSET-IDENTITY-GENERATION.md) and the shared owner-qualified SHA-256 materialization rule.

`exportAsset()` returns `KDNAStudioExport {bytes: Data, evidence: KDNAValue, binding: KDNAValue, verification: KDNAValue}`. The returned verification is pending saved readback. The embedding must perform an actual save and recapture before `completeSave(Data)`. Calling it with an in-memory copy cannot prove a filesystem operation. Session inspection and a static verifier result never reconstruct the one-use save context.

`inspect()` returns a copied value, phase and authority limits. `abort()` invalidates the live and pending capabilities. Revisions and previews become stale through session mutations; the API does not claim an unrelated wall-clock expiry or a cryptographic identity credential.
