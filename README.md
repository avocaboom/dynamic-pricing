# Dynamic Pricing Proxy

A Ruby on Rails API service that acts as a caching proxy for an expensive ML-based dynamic pricing model. Instead of hitting the upstream model on every request, this service caches rates for up to 5 minutes per unique `(period, hotel, room)` combination — reducing upstream calls while keeping rates fresh.

---

## Quick Start

```bash
# Build and start all services (app on :3000, rate-api on :8080)
docker compose up -d --build

# Sample request
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'

# Run full test suite
docker compose exec interview-dev ./bin/rails test

# Run specific test file
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb
```

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
| `pricing/v1/{period}/{hotel}/{room}` | 5 minutes | Fresh rate served to users |
| `pricing/v1/stale/{period}/{hotel}/{room}` | 1 hour | Fallback when upstream hits rate limit |

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
| Upstream error / timeout | Error returned to client. Stale **not** served — error codes and status mapping are in Section 2. |
| HTTP 429 (rate limit) + stale exists | Serve stale rate silently. User gets a response; rate is ≤ 1 hour old. |
| HTTP 429 (rate limit) + no stale | Return 503. Occurs only on the very first request for this key, or after the stale TTL also expires. |

**Why serve stale only on 429, not on all errors?**
Rate limit (429) is predictable and temporary — the upstream is healthy but throttling us. Serving slightly stale data is a reasonable trade-off. Other errors (timeout, 503) indicate the upstream may be returning incorrect data, so stale fallback would be misleading.

**Stale TTL (1 hour) — business decision pending:**
The 1-hour value is a reasonable default. The exact tolerance for stale pricing data should be determined based on business requirements (e.g., how often do hotel rates actually change in practice).

---

### 5. Observability — Structured Logging

All significant events are logged as JSON to `Rails.logger` for easy parsing by log aggregators (e.g., Datadog, CloudWatch).

**Log events**

| Event | Level | When |
|---|---|---|
| `pricing_cache` | `info` | Every request — includes `cache: "HIT"` or `"MISS"` |
| `pricing_rate_limit` | `warn` | Upstream returns 429 and stale cache is served |
| `pricing_rate_limit` | `error` | Upstream returns 429 and no stale cache available |
| `pricing_upstream_timeout` | `error` | `Net::OpenTimeout` or `Net::ReadTimeout` |
| `pricing_upstream_error` | `error` | Any other upstream failure — includes `error_class` and `message` |

**Example log lines**

```json
{"event":"pricing_cache","cache":"MISS","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}
{"event":"pricing_cache","cache":"HIT","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}
{"event":"pricing_rate_limit","action":"served_stale","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}
{"event":"pricing_upstream_error","error_class":"RuntimeError","message":"Rate not found for the given parameters","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}
```

**What is never logged:** The `RATE_API_TOKEN` value — it is read from an environment variable and never passed to the logger.

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
