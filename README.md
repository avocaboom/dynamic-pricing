# Dynamic Pricing Proxy

A Ruby on Rails API service that acts as a caching proxy for an expensive ML-based dynamic pricing model. Instead of hitting the upstream model on every request, this service caches rates for up to 5 minutes per unique `(period, hotel, room)` combination — reducing upstream calls while keeping rates fresh.

---

## Quick Start

```bash
# Build and start all services (app on :3000, rate-api on :8080)
docker compose up -d --build

# Enable caching in development (required — caching is off by default in Rails development mode)
docker compose exec interview-dev ./bin/rails dev:cache
docker compose restart interview-dev

# Sample request
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# Run full test suite
docker compose exec interview-dev ./bin/rails test

# Run specific test file
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb
```

### With monitoring stack (optional)

```bash
# Start everything including Grafana, Loki, Promtail, Prometheus
docker compose --profile monitoring up -d --build

# Grafana dashboard  → http://localhost:3001/d/dynamic-pricing  (no login required)
# Prometheus         → http://localhost:9090
```

Every response includes an `X-Request-Id` header. Paste the value into the **Request Flow Trace** panel in Grafana to filter all log lines for that single request end-to-end.

### E2E load test (optional)

Simulates realistic production traffic across a full 5-minute TTL cycle, all failure scenarios, and a concurrency stress test. Requires the monitoring stack to be running.

```bash
bash test/e2e/load_test.sh
```

The script uses shortened TTLs to keep total runtime manageable. The production defaults are automatically restored when the test completes.

| | Load test | Production default |
|---|---|---|
| `CACHE_TTL_SECONDS` | 180s (3 min) | 300s (5 min) |
| `STALE_CACHE_TTL_SECONDS` | 300s (5 min) | 3600s (1 hour) |

**What it runs:**

| Phase | Duration | Description |
|---|---|---|
| 1 — TTL cycle | ~4 min | 72 req/min (36 combinations × 2). Upstream called only on minute 1 and minute 4 (TTL expiry at 3 min). |
| 2 — Upstream timeout | ~1 min | Clears cache, pauses rate-api → all requests return `504 Gateway Timeout`. |
| 3 — Stale fallback | ~4 min | Warms cache slowly, waits 3 min for TTL to expire, exhausts token rate limit → requests return stale rate (`200`) instead of `503`. |
| 4 — Concurrency / capacity | ~2 min | **4a:** 50 concurrent requests to a single cold key — verifies upstream called exactly once (mutex coalescing). **4b:** Pre-warmed cache burst at 10 / 50 / 100 / 500 concurrent — measures avg latency per level. |

**What to watch in Grafana (`http://localhost:3001/d/dynamic-pricing`):**

| Panel | What to look for |
|---|---|
| Cache HIT vs MISS | 36 MISSes on minute 1, flat (all HIT) on minutes 2–3, 36 MISSes again on minute 4 |
| Requests per Minute | ~72 req/min across Phase 1, then spikes in Phase 2–3 |
| Upstream Calls | Spike on minute 1, flat on minutes 2–3, spike on minute 4, timeout on Phase 2 |
| Responses by Status | Mostly `200`, `504` spike in Phase 2 |
| Upstream Response by Status | `success` / `504 timeout` / `429 rate_limited` across phases |
| Cache Stale Fallback | `served_stale` events in Phase 3 |
| Upstream Calls (Phase 4a) | Exactly 1 `upstream_call` log for Summer/FloatingPointResort/SingletonRoom during the 50-concurrent burst — confirms mutex prevented thundering herd |
| Request Flow Trace | Paste any `X-Request-Id` to trace a single request end-to-end |

---

## API

### `GET /api/v1/pricing`

**Parameters**

| Parameter | Required | Valid values |
|---|---|---|
| `period` | Yes | `Summer`, `Autumn`, `Winter`, `Spring` |
| `hotel` | Yes | `FloatingPointResort`, `GitawayHotel`, `RecursionRetreat` |
| `room` | Yes | `SingletonRoom`, `BooleanTwin`, `RestfulKing` |

**Success response**

```json
{ "rate": "15000" }
```

**Error response**

```json
{ "error": "Descriptive message here" }
```

**HTTP status codes**

| Condition | Status |
|---|---|
| Success | `200 OK` |
| Invalid or missing parameters | `400 Bad Request` |
| Upstream service unavailable | `503 Service Unavailable` |
| Upstream request timed out | `504 Gateway Timeout` |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  CLIENT                                                         │
│  GET /api/v1/pricing?period=Summer&hotel=...&room=...           │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  BEFORE ACTION  validate_params                                 │
│                                                                 │
│  period ∈ [Summer, Autumn, Winter, Spring]?  ──── NO ──→ 400    │
│  hotel  ∈ [FloatingPointResort, ...]?        ──── NO ──→ 400    │
│  room   ∈ [SingletonRoom, ...]?              ──── NO ──→ 400    │
│                           │                                     │
│                          YES                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Api::V1::PricingService#run                                    │
│                                                                 │
│  cache_key = "pricing/v1/{period}/{hotel}/{room}"               │
│  Rails.cache.fetch(cache_key, expires_in: 5.minutes)            │
│                           │                                     │
│                  ┌────────┴────────┐                            │
│                 HIT              MISS                           │
│                  │                 │                            │
│                  ▼                 ▼                            │
│            return cached    RateApiClient.get_rate              │
│               rate               │                              │
│                             ┌────┴────┐                         │
│                           success   error                       │
│                             │         │                         │
│                             ▼         ▼                         │
│                       cache & return  errors << msg             │
│                          @result      http_status =             │
│                                       503 | 504                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  tripladev/rate-api  (Docker container :8080)                   │
│                                                                 │
│  POST /pricing                                                  │
│  Returns: { rates: [{ period, hotel, room, rate: "15000" }] }   │
└─────────────────────────────────────────────────────────────────┘
```

**Key components**

| File | Responsibility |
|---|---|
| `app/controllers/api/v1/pricing_controller.rb` | Input validation, delegates to service |
| `app/services/api/v1/pricing_service.rb` | Cache logic, upstream call, error handling |
| `app/services/base_service.rb` | Service contract: `valid?`, `result`, `errors`, `http_status` |
| `lib/rate_api_client.rb` | HTTParty wrapper for upstream rate-api |

---

## Design Decisions

### 1. Error status propagation via `http_status` in `BaseService`

The controller needs to return different HTTP status codes depending on the type of failure (400 for validation, 503 for upstream down, 504 for timeout). Rather than adding conditional logic in the controller or using exceptions for flow control, `BaseService` exposes an `http_status` accessor.

Each service sets `@http_status` to the appropriate status before adding to `errors`. The controller reads this value and passes it directly to `render`.

**Why not raise exceptions in the service?**
Exceptions-as-flow-control would require the controller to rescue specific exception classes — coupling the controller to service internals. The accessor approach keeps the controller clean and the service self-contained.

**Default:** `:bad_request` — validation errors are the most common failure mode.

---

### 2. HTTP timeout on `RateApiClient`

`default_timeout 5` sets both open and read timeout to 5 seconds on all upstream requests.

**Why 5 seconds?**
The upstream model is described as computationally expensive. Too short (e.g., 1s) risks false timeouts on slow-but-valid inference runs. Too long (e.g., 30s) risks Puma thread exhaustion under load — each hung request holds a thread until it times out.

5 seconds is a pragmatic middle ground. In production, this should be configurable via an environment variable.

**Exceptions raised on timeout:**
- `Net::OpenTimeout` — server unreachable within 5s
- `Net::ReadTimeout` — connected but no response within 5s

Both are caught in `PricingService` and mapped to `504 Gateway Timeout`.

---

### 3. Cache store: MemoryStore vs Redis

**Decision:** `MemoryStore` (Rails built-in, no additional infrastructure).

| Dimension | MemoryStore | Redis |
|---|---|---|
| Data loss on restart | Cache clears | Persistent |
| Multi-process (Puma workers) | Not shared between workers | Shared |
| Multi-instance (horizontal scale) | Not shared | Shared |
| Setup complexity | Zero (built-in) | Requires additional service |
| Latency | ~microseconds | ~1ms (network hop) |
| Failure mode | None | Redis down → all requests hit upstream |

**Why MemoryStore for this assignment:**
The constraint is 10,000 requests/day with a single API token. This maps to ~7 requests/minute — well within a single Puma process capacity. MemoryStore satisfies the requirement with zero additional infrastructure.

**Explicit scaling ceiling:**
This design assumes a **single Puma process**. If the service is scaled to multiple workers (`WEB_CONCURRENCY > 1`) or multiple instances, each process maintains its own cache. This would multiply upstream calls proportionally and risk violating the rate limit.

**Migration path to Redis:**
1. Add `gem "redis"` to Gemfile
2. Add Redis service to `docker-compose.yml`
3. Set `config.cache_store = :redis_cache_store, { url: ENV["REDIS_URL"] }` in `config/environments/production.rb`

No application code changes required — `Rails.cache` API is identical.

---

### 4. Caching strategy — Dual-key cache with stale fallback

The service uses two cache keys per unique `(period, hotel, room)` combination:

| Key | TTL | Purpose |
|---|---|---|
| `pricing/v1/{period}/{hotel}/{room}` | `CACHE_TTL_SECONDS` (default 5 min) | Fresh rate served to users |
| `pricing/v1/stale/{period}/{hotel}/{room}` | `STALE_CACHE_TTL_SECONDS` (default 1 hour) | Fallback when upstream hits rate limit |

On every successful upstream call, both keys are written. On cache miss, the fresh key is fetched from upstream and both keys are refreshed.

```ruby
Rails.cache.fetch("pricing/v1/#{period}/#{hotel}/#{room}", expires_in: 5.minutes) do
  rate = fetch_from_upstream          # raises on any failure
  Rails.cache.write(stale_key, rate, expires_in: 1.hour)
  rate
end
```

**Why `fetch` instead of manual `read`/`write`?**
`Rails.cache.fetch` is atomic — it reads, and only writes if the block executes. If the block raises (upstream error), nothing is cached. This prevents bad data from being stored.

**Cache key format: `pricing/v1/{period}/{hotel}/{room}`**
Plain string keys — readable in logs and debuggable. The `pricing/v1/` prefix namespaces keys for clarity and allows bulk invalidation by prefix if needed.

**Known constraint — upstream call volume:**
The 10,000 req/day refers to user requests to this service, not upstream calls. With a 5-minute TTL and 36 unique parameter combinations (4 periods × 3 hotels × 3 rooms), the worst-case upstream call volume is:

```
288 upstream calls/combination/day × 36 combinations = 10,368 upstream calls/day
```

This assumes all 36 combinations are actively requested throughout the day. The upstream `tripladev/rate-api` rate limit per token is not publicly documented, so this solution cannot be fully validated without knowing that limit. The stale fallback on HTTP 429 (described below) acts as the safety net.

**Failure behavior:**

| Condition | Behavior |
|---|---|
| Any upstream error + stale exists | Serve stale rate silently (`200`). Covers 429, timeout, 503, and all other errors. |
| Any upstream error + no stale | Return error to client (`503` or `504` depending on error type). |
| Upstream returns invalid rate (`0`, negative, non-numeric) | Always `503` — stale is never served, regardless of availability. |

**Why not serve stale for invalid rates?**
Invalid rate data (e.g. `"0"`) is a **data integrity problem**, not an availability problem. Upstream is reachable and responding — it is sending bad data. Serving stale would silently mask a bug in the pricing model. Unlike a timeout or 429 where the upstream is temporarily unable to respond correctly, an invalid rate means the upstream responded but its output cannot be trusted. The `InvalidRateError` bypasses `serve_stale_or_error` entirely and returns `503` directly.

**Why serve stale for all upstream errors (not just 429)?**
This is a **business decision** — both behaviors are technically valid:

- **Serve stale (current implementation):** Keeps the service available during upstream incidents. Acceptable if slightly outdated rates are tolerable — e.g., for display purposes where the user is not immediately transacting.
- **Return error on non-429:** Safer if rate accuracy is critical — e.g., when the rate is used directly in a booking transaction where a stale price could cause financial discrepancy.

The current implementation favors availability over strict accuracy. If the business requires rate freshness guarantees, stale fallback should be restricted to 429 only, and the stale TTL should be shortened accordingly.

**Stale TTL (1 hour) — business decision pending:**
The 1-hour value is a reasonable default. The exact tolerance for stale pricing data should be determined based on business requirements (e.g., how often do hotel rates actually change in practice).

---

### 5. Observability — Structured Logging

Structured logs are the first line of response when something goes wrong in production. Every event in this service — cache decisions, upstream calls, fallbacks, and HTTP requests — emits a single JSON line with a consistent schema. Because `request_id` is present on every line, the full lifecycle of any individual request can be reconstructed from logs.

All events are logged as single-line JSON using [Lograge](https://github.com/roidrage/lograge) for the HTTP request line and a custom logger in `PricingService` for business events. Every line follows the same schema:

```
{ "request_id", "time", "level", "msg", ...event-specific fields }
```

`request_id` appears first on every line, making it easy to grep all log lines belonging to a single request.

**Log events**

| `msg` | `level` | When |
|---|---|---|
| `request` | `info` / `warn` / `error` | Every HTTP request (via Lograge) — level follows HTTP status: 2xx→info, 4xx→warn, 5xx→error |
| `pricing_cache` | `info` | Every cache lookup — includes `cache: "HIT"` or `"MISS"` |
| `upstream_call` | `info` | Successful upstream fetch — includes `duration_ms` and `rate` |
| `upstream_call` | `warn` | Upstream returned 429 (rate limited) |
| `cache_write` | `info` | After a successful upstream call — includes `fresh_ttl_s` and `stale_ttl_s` |
| `stale_fallback` | `warn` | Upstream 429, stale cache served — includes `action: "served_stale"` |
| `stale_fallback` | `error` | Upstream 429, no stale available — includes `action: "no_stale_available"` |
| `upstream_timeout` | `error` | `Net::OpenTimeout` or `Net::ReadTimeout` |
| `upstream_error` | `error` | Any other upstream failure — includes `error_class` and `message` |

**Example log lines for a single request**

```json
{"request_id":"abc-123","time":"2026-06-05T06:25:09.891Z","level":"info","msg":"pricing_cache","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","cache":"MISS"}
{"request_id":"abc-123","time":"2026-06-05T06:25:09.909Z","level":"info","msg":"upstream_call","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","status":"success","duration_ms":18,"rate":"15000"}
{"request_id":"abc-123","time":"2026-06-05T06:25:09.910Z","level":"info","msg":"cache_write","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","fresh_ttl_s":300,"stale_ttl_s":3600}
{"request_id":"abc-123","time":"2026-06-05T06:25:09.922Z","level":"info","msg":"request","method":"GET","path":"/api/v1/pricing","status":200,"duration":45.95,"params":{"period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}}
```

**What is never logged:** The `RATE_API_TOKEN` value — it is read from an environment variable and never passed to the logger.

---

### 6. Request coalescing — per-key Mutex with double-checked locking

When concurrent requests hit the same cold cache key, each would independently call upstream without coordination. `PricingService` prevents this with a per-key `Mutex` — only the first thread calls upstream, the rest wait and read from cache.

```ruby
LOCKS = Concurrent::Map.new

# Fast path — skip lock entirely on cache hit (the common case)
cached = Rails.cache.read(cache_key)
return @result = cached if cached

# Slow path — serialize upstream calls per key
lock = LOCKS.compute_if_absent(cache_key) { Mutex.new }
lock.synchronize do
  cached = Rails.cache.read(cache_key)  # double-check after acquiring lock
  return @result = cached if cached

  rate = fetch_from_upstream
  Rails.cache.write(cache_key, rate, expires_in: CACHE_TTL)
  @result = rate
end
```

- **Double-check inside the lock** — two threads can both read MISS before either acquires the lock. The second thread re-reads cache after acquiring the lock and finds a HIT, skipping the upstream call.
- **Bounded** — `LOCKS` grows to at most 36 entries (4 × 3 × 3). No memory leak risk.

**Remaining limitation:** `Mutex` is in-process only — coalescing does not apply across Puma workers or multiple instances. Migration path: Redis-based distributed lock, no logic changes needed.

---

## Known Scaling Considerations

These are not bugs or missing features — they are deliberate trade-offs acceptable at 10k req/day on a single process. Each item describes when it becomes relevant and what the migration path looks like.

### 1. Multi-process / horizontal scale → MemoryStore cache not shared

`MemoryStore` is in-process only. With `WEB_CONCURRENCY > 1` or multiple instances, each process has its own cache. Upstream call volume multiplies proportionally, risking rate limit violations.

**Migration:** Replace `MemoryStore` with `RedisCache` — no application code changes needed, only config. See Design Decision 3.

### 2. Circuit breaker

If the upstream is persistently down, every cache MISS results in a 5-second timeout — tying up a Puma thread for each request. At low concurrency this is safe; at high concurrency it risks thread pool exhaustion.

At 10k req/day on a single process, concurrent upstream calls are rare. The stale fallback already absorbs most failure scenarios.

**Migration path:** Introduce a circuit breaker (e.g., `gem "stoplight"`) around `RateApiClient.get_rate`. When the upstream error rate exceeds a threshold, the circuit opens and requests fail fast — returning stale immediately without waiting for a timeout.

### 3. Synchronized cache expiry

When all 36 combinations are cached at the same time (e.g., after a cold start), they all expire at the same time — producing a predictable upstream call spike every 5 minutes.

```
t=0:00  Restart → 36 upstream calls → all 36 keys cached
t=5:00  All 36 keys expire simultaneously
t=5:01  36 requests → 36 upstream calls at once → repeat every 5 minutes
```

At 10k req/day this is unlikely to trigger the rate limit in practice, and the stale fallback absorbs failures if it does. At higher traffic or with a tighter upstream rate limit, this periodic spike becomes a real concern.

**Mitigation (not implemented):** Add jitter to the TTL so each key expires at a slightly different time:

```ruby
expires_in: CACHE_TTL - 30.seconds + rand(60).seconds  # ±30s around TTL
```

This distributes upstream calls evenly instead of batching them.

### 4. Cold start spike

On every service restart, `MemoryStore` is wiped — all 36 cache keys (fresh + stale) are lost. If all 36 combinations are requested within the first 5 minutes after restart, this produces a burst of up to 36 upstream calls in rapid succession, which may trigger the upstream rate limit depending on how tight it is.

**Current behavior:** The first request per key after restart hits upstream. If the rate limit is hit mid-burst, affected combinations return `503 Service Unavailable` — no fallback, since stale cache is also wiped on restart.

**Partial mitigation (implemented):** The per-key mutex ensures that concurrent requests for the **same key** during cold start only produce one upstream call — not N. This covers the thundering herd within a single key.

**Remaining gap:** If all 36 keys are requested simultaneously after restart, there will still be up to 36 concurrent upstream calls — one per key. The mutex cannot coalesce across different keys.

**Further mitigation options (not implemented):**
- Cache warming on startup: pre-populate all 36 combinations during `config/initializers` or a startup task
- Rate-paced warm-up: spread the 36 upstream calls over the first TTL window to avoid burst

### 5. MemoryStore memory limit

Rails `MemoryStore` defaults to a **32MB cap**. When the limit is reached, Rails evicts the least-recently-used entries silently — no error, no warning, just a cache miss.

For this service: 36 combinations × 2 keys (fresh + stale) × ~200 bytes per entry ≈ **~15KB total**. This is negligible and will never approach the 32MB limit given the current parameter space.

**When it becomes relevant:** If the parameter space grows significantly (more hotels, rooms, or periods), or if `Rails.cache` is shared with other parts of the application for larger payloads, the limit should be monitored. The cap is configurable: `config.cache_store = :memory_store, { size: 64.megabytes }`.

---

## Assumptions

- Service runs as a **single Puma process** (see cache store decision above)
- A rate remains valid for exactly **5 minutes** regardless of market conditions (per assignment spec)
- Stale pricing data up to **1 hour old** is acceptable as a fallback when the upstream rate limit (429) is hit
- Upstream timeout of **5 seconds** is sufficient for ML inference
- Upstream API token (`RATE_API_TOKEN`) is stable and does not rotate during runtime

---

## AI Usage

This solution was developed with assistance from Claude (Anthropic) as part of a standard development workflow.

**Parts developed with AI assistance:**
- Initial scaffolding review and gap analysis against assignment requirements
- README structure and documentation
- Test case design (identifying edge cases for cache behavior)

**Workflow:**
- All design decisions were made by the developer and discussed interactively
- Code was reviewed and understood before acceptance
- AI was used as a pair-programming tool, not as a code generator
