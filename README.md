# StrongMind GitHub Push Ingest

Internal service that ingests GitHub public Push events into PostgreSQL (Docker Compose).

## Start the system

```bash
docker compose up --build
```

Starts Postgres, Redis, MinIO, the Rails API (`web` on :3000), and Sidekiq.

## Run ingestion

```bash
docker compose run --rm ingest
```

(Currently a stub that confirms Docker wiring; the real pipeline lands in a later step.)

## Run tests

```bash
docker compose run --rm test
```

## Logs

```bash
docker compose logs -f
```

## How to verify it’s working

### Step 2 — Docker wiring
1. `docker compose up --build` — wait until `web` / `sidekiq` stay up (no crash-loop).
2. `curl -s http://localhost:3000/up` — expect `200` / green.
3. Open MinIO console at http://localhost:9001 (user/pass: `minioadmin` / `minioadmin`).
4. `docker compose run --rm ingest` — expect `[ingest] Stub OK`.
5. `docker compose run --rm test` — RSpec exits 0 (may be 0 examples until later steps).

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
