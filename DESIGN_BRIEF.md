# Design Brief — GitHub Push Event Ingest

## Problem understanding

StrongMind needs better visibility into GitHub activity. This service is an **unattended internal ingest pipeline**: poll the public GitHub Events API (no auth token), keep only `PushEvent`s, store durable raw + structured records in PostgreSQL, enrich actor/repository data from payload URLs, and remain predictable under rate limits, duplicates, and restarts.

Success looks like: a reviewer can `docker compose up --build`, observe clear stdout logs, query structured push rows, and re-run ingest without corrupting or duplicating data.

## Architecture

```text
GitHub /events  -->  ingest-worker (Rails rake loop)
                         | upsert PushEvent (unique github_event_id)
                         | enqueue StoreRawEventJob
                         | enqueue EnrichPushEventJob
                         v
                    Sidekiq (concurrency 1)
                         | fetch actor.url / repo.url (TTL cache)
                         | upload avatar (once)
                         v
              PostgreSQL  +  MinIO (raw JSON + avatars)
```

**Stack:** Rails 8 API-only, PostgreSQL, Redis + Sidekiq, Faraday, MinIO via `aws-sdk-s3`, Docker Compose.

**Why this shape:** Ingest stays thin and fast (filter + upsert + enqueue). Enrichment and object I/O are asynchronous so a slow GitHub/MinIO call cannot block polling, and Sidekiq concurrency can bound fan-out.

## Data model (high level)

- **`push_events`**: system of record for each GitHub event. Unique `github_event_id`. Queryable columns: `repository_id`, `push_id`, `ref`, `head`, `before`. Full payload in `raw_payload` (jsonb). Optional `raw_object_key` for MinIO. `enrichment_status` tracks `pending` / `enriched` / `failed`.
- **`actors` / `repositories`**: normalized enrichment caches keyed by GitHub id, with `fetched_at` for TTL freshness and durable object keys for avatars.
- **FKs:** `push_events.actor_id`, `push_events.repository_record_id` (named to avoid clashing with GitHub’s numeric `repository_id` column).

## Rate limits & fan-out (Extension A)

Unauthenticated GitHub REST is roughly **60 requests/hour**, shared by poll + enrichment.

Controls:

1. **Poll interval** defaults to 60s; longer idle sleep on `304` / rate-limit paths.
2. **ETag / If-None-Match** on `/events` to avoid wasteful body downloads when unchanged.
3. **Header-aware waits** on `X-RateLimit-*` and `Retry-After`; preemptive sleep when remaining is low.
4. **No inline enrichment during ingest** — jobs are enqueued instead.
5. **Sidekiq concurrency = 1** on enrichment to prevent request amplification.
6. On rate limit during enrichment, **re-queue after reset** rather than busy-retry.

Assumption: demonstrating correct backoff matters more than maximizing throughput without a token.

## Idempotency & restart safety (Extension B)

- Unique index on `push_events.github_event_id` makes duplicate polls no-ops.
- Re-ingest does not re-enqueue enrichment/storage for existing rows.
- Enrichment is idempotent: already-`enriched` events short-circuit; actor/repo upserts are keyed by GitHub id.
- Object keys are deterministic (`raw-events/{event_id}.json`, `avatars/{github_id}.*`); existence checks skip re-upload/re-download.
- Malformed events are logged and skipped; unexpected errors in the ingest loop are caught so the worker does not crash-loop.

Tradeoff: we do **not** implement retention/compaction. Unbounded historical growth is accepted for this exercise; production would add TTL/archival.

## Object storage (Extension C)

MinIO stands in for S3 locally. Raw event JSON is uploaded asynchronously after insert. Avatars are downloaded once during enrichment when `avatar_object_key` is blank. Failures in avatar storage are best-effort (structured enrichment still succeeds).

## Testing strategy (Extension D)

RSpec + WebMock cover mapper, rate-limit math, events client status handling, idempotent ingest, enrichment cache hits, job failure/requeue, and upload-once storage behavior.  
`docker compose run --rm test` is the reviewer entrypoint.

Intentionally not tested: live GitHub, full multi-hour Compose soak, UI.

## Operability

Structured stdout logs (`[ingest]`, `[enrich]`, `[storage]`, `[job]`) are meant to be readable via `docker compose logs -f`. Health is exposed at `GET /up`.

## Key tradeoffs & assumptions

| Choice | Why |
|---|---|
| Rails API-only | Preferred stack; enough structure for jobs/models without a UI |
| Sidekiq over inline enrich | Bounds fan-out; survives process restarts better than in-process threads |
| No GitHub token | Matches brief; forces honest rate-limit design |
| Dev Compose defaults (shared secrets) | Local reviewer DX only — not production hardening |
| 24h enrichment TTL | Avoids repeated fetches without pretending profiles never change |

## Intentionally not built

- AuthN/Z, multi-tenant API, or analyst UI/dashboard
- Historical backfill beyond the public events stream window
- Authenticated GitHub API / higher quotas
- Warehouse/analytics transforms, retention policies, alerting
- Production secrets management / Kamal deploy target (Compose is the deliverable runtime)

## Known issues found and fixed during final testing

Before submitting, I re-ran the reviewer flow end-to-end from a clean checkout (fresh clone, `docker compose up --build`, cold database/volumes) rather than relying only on the existing test suite, and found four real bugs the specs didn't catch. All were fixed, covered with regression tests, and verified against a second clean checkout:

1. **Actor enrichment crashed on real bot accounts.** GitHub's live public events API returns `actor.url` with literal, unescaped brackets for bot accounts (e.g. `.../users/github-actions[bot]`), which is not a valid URI and raised `URI::InvalidURIError`. Bots (`github-actions[bot]`, `dependabot[bot]`, `renovate[bot]`, etc.) are extremely common in the real event stream, so this was hitting a large fraction of enrichment jobs, not an edge case. Fixed by sanitizing any actor/repo URL (both GitHub-supplied and our own fallback-constructed one) before fetching, and by treating `URI::InvalidURIError` as a permanent, non-retryable job failure instead of letting Sidekiq retry indefinitely on the same bad input.
2. **The Sidekiq enrichment worker blocked on rate-limit waits.** With `Sidekiq` concurrency 1, a preemptive rate-limit sleep inside the job stalled every other queued job (including cheap raw-event uploads) for up to the ~1 hour reset window. Fixed by raising instead of sleeping; the job now re-enqueues with a delay, freeing the worker thread. Work already fetched before the limit was hit is persisted rather than discarded.
3. **The one-shot reviewer command could hang for up to an hour.** `docker compose run --rm ingest` shared the same GitHub quota as the continuous `ingest-worker`, so if the quota was already low, the one-shot command would block on the same sleep-based backoff as the long-running loop. Fixed by making the runner's backoff non-blocking in one-shot mode: it logs the wait it would need and returns immediately (exit 0), while continuous polling keeps sleeping/retrying normally.
4. **`web` and `ingest-worker` raced to initialize the schema on a fresh database.** Both containers call `rails db:prepare` on startup; on a brand-new Postgres volume this occasionally lost a race and crash-looped one container with a `PG::UniqueViolation` on a fresh clone's very first `docker compose up`. Fixed with a small retry-on-failure loop in the entrypoint: the loser simply retries a few seconds later, by which point the winner has already loaded the schema.

**Verification note:** all four fixes were re-confirmed against a brand-new clone after the fixes were pushed, not just in the environment where they were found. The schema race (#4) is the flakiest of the four by nature, so it was stress-tested hardest: 11 separate `docker compose up`-on-a-fresh-volume cycles, each torn down (`down -v`) before the next. The race actually triggered in the large majority of those runs — sometimes `ingest-worker` lost it, once `web` lost it, on two different Postgres catalog constraints (`pg_class_relname_nsp_index`, `pg_type_typname_nsp_index`) — and every single time the retry recovered cleanly with all containers reaching `Up`. The bot-account URL fix (#1) was checked directly against a live `actor.url` value pulled from the real GitHub events API, not just a synthetic test fixture.

## Removed unused Rails scaffolding

`rails new` generates deploy/CI/test tooling this exercise doesn't use. Rather than leave it in as unreviewed dead weight, it was removed as a final pass:

- **Kamal** (`.kamal/`, `config/deploy.yml`, `bin/kamal`, the `kamal` gem) — deploy-to-a-server tooling with no target here; Compose is the deliverable runtime, and this is called out explicitly under "Intentionally not built" above.
- **GitHub Actions CI + Dependabot** (`.github/workflows/ci.yml`, `.github/dependabot.yml`) — the generated CI workflow actually ran the *wrong* test suite (`bin/rails db:test:prepare test`, i.e. Minitest) and never provisioned Redis or MinIO, so it would not have exercised this project's real RSpec suite or caught any of the bugs above even if left in place; keeping a CI workflow that silently doesn't test anything real seemed worse than having none. Dependabot had already opened a handful of dependency-bump PRs against default settings I never configured.
- **The unused Minitest `test/` directory** — this project's tests are RSpec under `spec/` (`docker compose run --rm test`); the generated Minitest stubs under `test/` never ran and would only confuse a reviewer about which suite is authoritative.

`Gemfile`/`Gemfile.lock` were regenerated after removing the `kamal` gem; `rubocop` (49 files, no offenses) and the full RSpec suite (32 examples, 0 failures) were re-run against the trimmed tree, and a full `docker compose up` was re-verified end to end.

## What “done” means

From a clean checkout: `docker compose up --build` runs without crash-looping; ingest creates durable PushEvent rows; enrichment attaches actor/repo when quota allows; MinIO holds raw/avatar objects; tests pass under Compose; operators can diagnose behavior from logs alone.
