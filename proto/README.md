# proto — shared wire schemas

Source-of-truth JSON Schemas for every message that crosses the worker↔coordinator
boundary. The Rust worker derives serde types that conform to these; the Elixir coordinator
validates inbound payloads against them.

| schema | direction | purpose |
|--------|-----------|---------|
| `registration.schema.json` | worker → coordinator | worker capabilities / models / privacy / limits. **No secrets.** |
| `usage_report.schema.json`  | worker → coordinator | aggregated usage metrics. **No secrets.** |
| `job.schema.json`           | coordinator → worker | leased job incl. privacy level |
| `job_result.schema.json`    | worker → coordinator | normalized result |
| `job_result_chunk.schema.json` | worker → coordinator | streamed content fragment of a running job (best-effort; the final `job_result` stays authoritative) |

## Hard invariant

None of these schemas contain a `token`, `api_key`, `authorization`, `secret`, or raw
header field. The coordinator additionally strips/rejects any such field if it ever appears
on an inbound payload (defense in depth). Tests in both worker and coordinator assert this.
