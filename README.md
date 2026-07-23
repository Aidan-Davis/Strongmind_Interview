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

## How to verify it’s working

Give the stack 1–2 minutes after `up --build` for the first poll/enrichment cycle (longer if GitHub rate limits are exhausted).

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

Expect structured push columns populated without JSON parsing, and enriched rows joined to actor/repo.

Idempotency check: run `docker compose run --rm ingest` twice quickly — duplicate `github_event_id` rows should not appear (`count(*)` equals `count(DISTINCT github_event_id)`).

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
docker compose logs --tail 80 sidekiq
```

Expect `[enrich] actor_fetch` or `actor_cache_hit`, then `enriched`, plus `[storage] raw_uploaded` / `avatar_uploaded` (or `*_exists`).

If you see `preemptive_rate_limit_wait` / `rate_limited` with a large `wait_seconds`, the unauthenticated GitHub quota (~60 req/hour) is exhausted. Workers stay up and resume after reset — that is expected.

### 6. Tests

```bash
docker compose run --rm --build test
```

Expect RSpec examples to pass (no live GitHub dependency).

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
