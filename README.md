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

## How to verify it’s working (step 2)

1. `docker compose up --build` — wait until `web` / `sidekiq` stay up (no crash-loop).
2. `curl -s http://localhost:3000/up` — expect `200` / green.
3. Open MinIO console at http://localhost:9001 (user/pass: `minioadmin` / `minioadmin`).
4. `docker compose run --rm ingest` — expect `[ingest] Stub OK`.
5. `docker compose run --rm test` — RSpec exits 0 (may be 0 examples until later steps).
