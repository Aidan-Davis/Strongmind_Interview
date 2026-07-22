# StrongMind GitHub Push Ingest

Internal service that ingests GitHub public Push events into PostgreSQL (Docker Compose).

## Start the system

```bash
docker compose up --build
```

Starts Postgres, Redis, MinIO, the Rails API (`web` on :3000), Sidekiq, and a continuous `ingest-worker`.

## Run ingestion

One-shot poll (reviewer command):

```bash
docker compose run --rm ingest
```

Continuous polling also runs via `ingest-worker` when the stack is up (`INGEST_MODE=loop`).

## Run tests

```bash
docker compose run --rm test
```

## Logs

```bash
docker compose logs -f
docker compose logs -f ingest-worker sidekiq
```

## How to verify it’s working

### Step 2 — Docker wiring
1. `docker compose up --build` — wait until `web` / `sidekiq` stay up (no crash-loop).
2. `curl -s http://localhost:3000/up` — expect `200` / green.
3. Open MinIO console at http://localhost:9001 (user/pass: `minioadmin` / `minioadmin`).
4. `docker compose run --rm test` — RSpec exits 0 (may be 0 examples until later steps).

### Step 3 — Schema / models
```bash
docker compose exec web ./bin/rails runner 'puts ActiveRecord::Base.connection.tables.sort.inspect'
```
Expect `actors`, `push_events`, and `repositories` present.

```bash
docker compose exec db psql -U postgres -d strongmind_interview_development -c '\dt'
docker compose exec db psql -U postgres -d strongmind_interview_development -c '\d push_events'
```
Confirm unique index on `push_events.github_event_id` and FKs to `actors` / `repositories`.

### Step 4 — Ingest pipeline
```bash
docker compose up --build -d
docker compose run --rm ingest
docker compose logs --tail 50 ingest-worker
```
Expect logs like `[ingest] poll_start`, `[ingest] poll_complete`, and `created=` / `seen=` counts.

```bash
docker compose exec db psql -U postgres -d strongmind_interview_development \
  -c 'SELECT github_event_id, repository_id, push_id, ref, enrichment_status FROM push_events ORDER BY id DESC LIMIT 10;'
```
Expect PushEvent rows with structured columns. Re-run `docker compose run --rm ingest` — row count for the same `github_event_id`s should not grow (idempotent upserts).

### Step 5 — Enrichment
```bash
docker compose up --build -d
docker compose run --rm ingest
docker compose logs -f sidekiq
```
Expect `[enrich] actor_fetch` / `repo_fetch` (or `*_cache_hit`), then `enriched`.

```bash
docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT enrichment_status, count(*) FROM push_events GROUP BY 1 ORDER BY 1;"

docker compose exec db psql -U postgres -d strongmind_interview_development -c \
  "SELECT pe.id, pe.enrichment_status, a.login, r.full_name
   FROM push_events pe
   LEFT JOIN actors a ON a.id = pe.actor_id
   LEFT JOIN repositories r ON r.id = pe.repository_record_id
   ORDER BY pe.id DESC LIMIT 10;"
```
Expect `enriched` rows with actor login + repository full_name. Re-enrichment of the same actor/repo should log cache hits within 24h.
