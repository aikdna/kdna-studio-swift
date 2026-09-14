# Current shared session identity generation

This supplements the fixed API and schema-identity dependency amendment without adding a public setter or changing materialization rule 2.

At createSession, generate three independent standard random UUIDs, serialized lowercase: session_id is `session:` plus the first, asset_id is `asset:` plus the second, and asset_uid is `urn:uuid:` plus the third. Capture createdAt at session creation as UTC ISO8601 with exactly three fractional millisecond digits and Z. The asset identity remains fixed for that session.

The frozen context carries `asset:{asset_id,asset_uid,version:'0.1.'+revision}` where revision is the actual current nonnegative integer session revision. No identity or version setter is exposed. Every creation event and revision transition must follow the fixed session implementation; do not derive identity from title or import old state. Version remains bound in the whole context, while stable owner-qualified J/C IDs deliberately exclude it.

Each material id is `material:` plus a fresh independent UUID, with recorded_at from the actual recordMaterial call in the same timestamp representation. Each review id is `review:` plus a fresh independent UUID. The embedding supplies actual response IDs; Studio checks uniqueness and current binding. UUIDs/timestamps are generation conventions, not identity authentication.

A Swift producer may use native UUID generation with lowercase serialization and the same timestamp shape. When verifying peer evidence, preserve its literal values; do not normalize UUID spelling, regenerate identifiers, reset revision or reformat timestamps. Current producer coordinates remain JS @aikdna/kdna-studio-core 4.0.0-rc.components.1 and Swift KDNAStudioCore 0.6.0-rc.components.1. Both bind Core 0.24.0-rc.component-semantics.2 in their current context.
