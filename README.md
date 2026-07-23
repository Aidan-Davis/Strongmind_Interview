# StrongMind GitHub Push Ingest

Unattended Rails service that polls the GitHub public events API, persists PushEvents in PostgreSQL, enriches actor/repository data via Sidekiq, and stores raw payloads + avatars in MinIO.

See [DESIGN_BRIEF.md](DESIGN_BRIEF.md) for architecture and tradeoffs.

## Prerequisites

- Docker Desktop (or another Docker Engine + Compose v2)
- macOS is the expected local environment

## Start the system

```bash
docker compose up --build
```

Starts:

| Service | Role |
|---|---|
| `db` | PostgreSQL |
| `redis` | Sidekiq backend |
| `minio` | S3-compatible object storage (+ console on :9001) |
| `web` | Rails API health endpoint on :3000 |
| `sidekiq` | Enrichment + object-storage jobs |
| `ingest-worker` | Continuous PushEvent polling |

## Run ingestion

One-shot poll (reviewer command):

```bash
docker compose run --rm ingest
```

Continuous ingestion also runs automatically via `ingest-worker` while the stack is up.

One-shot mode never blocks on GitHub rate limits: if the shared unauthenticated
quota (~60 req/hour, shared with `ingest-worker`/`sidekiq`) is already low or
exhausted when you run it, the command logs `rate_limited` /
`preemptive_rate_limit_wait` with the wait it *would* need and returns
immediately (exit 0) instead of hanging for up to the ~1 hour reset window.
Continuous polling via `ingest-worker` keeps running and resumes automatically
once the quota resets — only the one-shot CLI command short-circuits.

## Exit codes

`bin/rails ingest:run` (used by both `ingest` and `ingest-worker`) follows a
deliberate contract:

- **Exit 0** whenever a cycle *completed* — including a cycle that did no work because
  the rate-limit budget was spent. A spent budget is expected operation, not failure.
- **Non-zero** is reserved for misconfiguration a restart could actually fix (for
  example, the database or Redis unreachable at boot).

Transient failures (timeouts, 5xx, 429, rate-limited 403) are retried with bounded
backoff and then the cycle is abandoned and logged; the process stays alive rather
than exiting non-zero. Because a transient GitHub error never becomes a non-zero
exit, `ingest-worker` is safe to run under a restart policy (e.g.
`restart: on-failure`) without crash-looping.

## Run tests

```bash
docker compose run --rm --build test
```

## Logs

```bash
docker compose logs -f
docker compose logs -f ingest-worker sidekiq
```

Logs are written to stdout/stderr as structured lines like `[ingest] …`, `[enrich] …`, `[storage] …`, `[job] …`.

If the shared GitHub quota is exhausted, the continuous `ingest-worker` waits for it to reset and emits a `[ingest] waiting seconds_remaining=…` countdown (every ~30s) rather than going silent — so a quiet log during a wait is expected, not a hang.

## How to verify it’s working

Give the stack 1–2 minutes after `up --build` for the first poll/enrichment cycle (longer if GitHub rate limits are exhausted).

**Headline check (idempotency).** Re-running ingestion must never duplicate rows —
this is the core durability guarantee. Run the one-shot twice and confirm the counts
match:

```bash
docker compose run --rm ingest
docker compose run --rm ingest

docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT count(*) AS rows, count(DISTINCT github_event_id) AS distinct_ids FROM push_events;"
```

`rows` must equal `distinct_ids`. The heavily overlapping feed means the second run
adds few or no new rows and re-enqueues nothing already enriched.

### 1. Health

```bash
curl -i http://localhost:3000/up
```

Expect HTTP **200**.

### 2. Ingest logs

```bash
docker compose logs --tail 50 ingest-worker
docker compose run --rm ingest
```

Expect `[ingest] poll_start` and `[ingest] poll_complete` with `seen=` / `created=` / `skipped=`.

### 3. Database records

```bash
docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT github_event_id, repository_id, push_id, ref, head, before, enrichment_status
   FROM push_events ORDER BY id DESC LIMIT 10;"

docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT enrichment_status, count(*) FROM push_events GROUP BY 1 ORDER BY 1;"

docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT pe.id, a.login, r.full_name
   FROM push_events pe
   LEFT JOIN actors a ON a.id = pe.actor_id
   LEFT JOIN repositories r ON r.id = pe.repository_record_id
   WHERE pe.enrichment_status = 'enriched'
   ORDER BY pe.id DESC LIMIT 10;"
```

Expect structured push columns populated without JSON parsing, and enriched rows joined to actor/repo. (Re-run safety is covered by the headline idempotency check above.)

### 4. Object storage

```bash
docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT id, raw_object_key FROM push_events WHERE raw_object_key IS NOT NULL ORDER BY id DESC LIMIT 5;"

docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT login, avatar_object_key FROM actors WHERE avatar_object_key IS NOT NULL LIMIT 5;"
```

MinIO console: http://localhost:9001  
Login: `minioadmin` / `minioadmin`  
Bucket: `github-ingest` → `raw-events/` and `avatars/`

### 5. Enrichment / job logs

```bash
docker compose logs sidekiq | grep -E "\[enrich\]|\[storage\]" | tail -20
```

(Grep the full log, then `tail`. Avoid `docker compose logs --tail N sidekiq | grep …`: because Sidekiq is chatty, the `[enrich]` lines can scroll past the last N lines and grep returns nothing even though enrichment worked.)

Expect `[enrich] actor_fetch` or `actor_cache_hit`, then `enriched`, plus `[storage] raw_uploaded` / `avatar_uploaded` (or `*_exists`).

If you see `preemptive_rate_limit_wait` / `rate_limited` with a large `wait_seconds`, the unauthenticated GitHub quota (~60 req/hour) is exhausted. Workers stay up and resume after reset — that is expected.

### 6. Tests

```bash
docker compose run --rm --build test
```

Expect RSpec examples to pass (no live GitHub dependency).

## Requirements traceability

Every story and extension maps to a specific spec, so a reviewer can jump straight
from an acceptance criterion to the test that proves it. Run the whole suite with
`docker compose run --rm --build test`.

| Story / Extension | Acceptance criterion | Where it's proven |
|---|---|---|
| Story 1 - Ingest | Only `PushEvent`s are processed | [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb) |
| Story 1 - Ingest | Each event persisted durably | [spec/models/push_event_spec.rb](spec/models/push_event_spec.rb) |
| Story 1 - Ingest | Repeatable without duplication | [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb) ("is idempotent...") |
| Story 2 - Persist | Raw payload retained | [spec/models/push_event_spec.rb](spec/models/push_event_spec.rb) |
| Story 2 - Persist | `repository_id`/`push_id`/`ref`/`head`/`before` queryable as columns | [spec/services/ingest/push_event_mapper_spec.rb](spec/services/ingest/push_event_mapper_spec.rb) |
| Story 3 - Enrich | Actor/repo fetched from payload URLs, persisted | [spec/services/ingest/enrich_push_event_spec.rb](spec/services/ingest/enrich_push_event_spec.rb) |
| Story 3 - Enrich | No unnecessary repeated fetches (TTL cache) | [spec/services/ingest/enrich_push_event_spec.rb](spec/services/ingest/enrich_push_event_spec.rb) |
| Story 4 - Operability | Malformed data handled gracefully | [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb) ("skips malformed...") |
| Story 4 - Operability | No crash-loop; transient retries vs. permanent failures | [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb) (loop backoff), [spec/jobs/enrich_push_event_job_spec.rb](spec/jobs/enrich_push_event_job_spec.rb) (requeue vs. mark `failed`) |
| Ext. A - Rate limits | Header-aware waits / preemptive backoff | [spec/services/github/rate_limit_spec.rb](spec/services/github/rate_limit_spec.rb), [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb) (backoff) |
| Ext. B - Idempotency | Duplicate events + restart safety | [spec/services/ingest/push_events_runner_spec.rb](spec/services/ingest/push_events_runner_spec.rb), [spec/models/push_event_spec.rb](spec/models/push_event_spec.rb) |
| Ext. C - Object storage | Upload-once, durable references | [spec/services/object_storage/raw_event_uploader_spec.rb](spec/services/object_storage/raw_event_uploader_spec.rb), [spec/services/object_storage/avatar_uploader_spec.rb](spec/services/object_storage/avatar_uploader_spec.rb) |
| Ext. D - Testing | Deterministic, offline suite | all of the above (`WebMock.disable_net_connect!` in [spec/rails_helper.rb](spec/rails_helper.rb)) |

## Useful ports

| Port | Service |
|---|---|
| 3000 | Rails `/up` |
| 5432 | Postgres |
| 6379 | Redis |
| 9000 | MinIO API |
| 9001 | MinIO Console |

## Design notes

Architecture, data model, rate-limit strategy, and intentional non-goals are documented in [DESIGN_BRIEF.md](DESIGN_BRIEF.md).
