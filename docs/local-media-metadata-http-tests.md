# Local media metadata HTTP sequence coverage

Independent `codex/test-local-metadata-http` from `b79bfa23083103a3ff0cddecf53831f755922550`. This slice adds only a new test file and documentation/log entries. It does not modify `LibraryMutationClient`, the decoder, media routing, automatic matching UI, server, raw schema or workflows. Root owns final integration and CI.

`LocalMediaMetadataHTTPTests` constructs the real client with a private ephemeral URLSession configuration. A private URLProtocol intercepts **all** requests of that session, including unknown hosts, and fails rather than falling back to the network. Each test has its own random `.invalid` host and finite actor-script responses. Request capture preserves the real method, prefix/path/query, Bearer/Accept/Content-Type and body/body-stream bytes. The responder sends actual HTTPURLResponse headers, multiple Data chunks and normal EOF or transport errors through Foundation; it never calls the decoder directly or substitutes its return value.

## Contracts checked

| Scope | Assertions |
| --- | --- |
| Exact read sequence | GET `/prefix/api/sync/ack` with no body, then POST `/prefix/api/sync/stream` with body exactly `{"types":["AssetMetadataV1"]}`. No reset flag, ACK submission/deletion, other entity type, query parameter or media path. Each request keeps the synthetic Bearer header and its precise Accept/Content-Type. |
| Complete golden stream | Independent JSONL envelopes, delete history, an unrelated opaque-ID suffix, two candidates with the same full case/Unicode/space/slash/percent/pipe-containing ID, and UUID SyncComplete ack.17-byte transport chunks split JSON and UTF8. Both ambiguous candidates and all string metadata values remain intact. MIME case and charset are accepted. |
| Freshness | Two reads on one real client produce four actual requests. A second complete empty stream returns no old candidates; no persistent completed GET is reused and no acknowledgements are sent. |
| Early refusal | Empty input sends no probe; invalid input fails before HTTP. Metadata upsert/delete checkpoints stop after the real GET. Non200 ACK responses stop before stream. |
| Stream refusal | Non200 statuses, absent/wrong MIME, normal EOF without completion, half completion line, actual URLProtocol connection-loss error and SyncReset fail instead of returning earlier candidates. No compensating reset or ACK call appears. |
| Cancellation | A pre-cancelled Task cannot start GET. Four gated cases hold the real ACK or the stream after delivering chunks, cancel either the parent Task or client URLSession, then release only for cleanup. The original call must throw cancellation and cannot return a partial value or send an extra request. |

There are **11 test functions /28 parameterized cases**, separate from the existing17 decoder-only cases. Gate waits observe actual responder entry, and a watcher reports if the operation finishes before the gate; the fixture does not use fixed sleeps or fake a successful entry. Mutex-protected stopLoading/task ownership and explicit `@Sendable [weak self, capturedRequest, script]` follow the already-used HTTP fixture pattern. Responder cancellation suppresses later callbacks instead of bypassing URLSession cancellation.

The gate tests release late bytes to guarantee cleanup; they do not measure how quickly a real socket stops or assert that a backend aborts its job immediately. This is client HTTP byte/sequence coverage without sockets, not a running-server black-box acceptance or a device PhotoKit test.

## Source evidence and actual checks

Actual parent server inspection was at `c72b4d5cd4aa034c30e22c54992d306b89fe135c`. `server/src/controllers/sync.controller.ts` supplies GET ack (`SyncCheckpointRead`) and POST stream (`SyncStream`), explicit stream200 and `application/jsonlines+json`. `server/src/utils/sync.ts:serialize/toAck/mapJsonLine` supplies `{type,data,ack}` plus newline, with ack as entity/update IDs joined by pipes. `sync.service.ts:syncAssetMetadataV1` emits delete rows and upserts containing assetId/key/value; `dtos/sync.dto.ts:SyncAssetMetadataV1Schema` preserves the value dictionary. The golden is independent literal data shaped to those owning sources; no production media, account or checkpoint was accessed.

Actual NAS checks: scoped SwiftFormat0.64.5 format/lint, `git diff --check`, static literal JSON/protocol/UTF8-chunk verification, and confirmation that this diff changes no production client. NAS has no Swift/Xcode: these tests are **written but not executed or compiled**. Existing candidate API/App/UI results do not validate this independent branch. Root must run compilation and the tests on macOS after integration.

Real server public HTTP, official-client coexistence, automatic full-library matching, persistent association lifecycle, local image/video routing, cache invalidation and phone/tablet UI remain owned by their separate integration/acceptance work. This test slice cannot claim end-to-end local-first browsing is complete. Rollback removes only these tests/docs; no recovery or server/media data changes exist.
