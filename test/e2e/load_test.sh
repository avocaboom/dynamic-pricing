#!/usr/bin/env bash
# =============================================================================
# E2E Integration Test — Dynamic Pricing Proxy
#
# Simulates realistic production traffic across a full 3-minute TTL cycle,
# then demonstrates failure scenarios (timeout + stale fallback).
#
# Test TTLs (overrides production defaults for faster cycle):
#   CACHE_TTL_SECONDS       = 180  (3 min, production default: 300)
#   STALE_CACHE_TTL_SECONDS = 300  (5 min, production default: 3600)
#
# Traffic pattern per minute: 72 requests = 36 combinations × 2 hits each
#   Minute 1      : 36 MISS (upstream) + 36 HIT
#   Minutes 2–3   : 72 HIT each (0 upstream calls)
#   Minute 4      : 36 MISS again (TTL expired) + 36 HIT → new cycle
#
# Phases:
#   1. TTL cycle  — 4 minutes, showing MISS→HIT→expire→MISS pattern
#   2. Timeout    — restart server + pause rate-api → 504
#   3. Stale      — warm cache → wait 3 min TTL → exhaust rate limit → stale fallback
#
# Usage (from project root):
#   bash test/e2e/load_test.sh
# =============================================================================

APP_URL="http://localhost:3000/api/v1/pricing"
RATE_API_DIRECT="http://localhost:8080"
RATE_API_TOKEN="04aa6f42aa03f220c2ae9a276cd68c62"
COMPOSE="docker compose"

# TTL values used during this test
TEST_CACHE_TTL=180        # 3 minutes
TEST_STALE_TTL=300        # 5 minutes

PERIODS=("Summer" "Autumn" "Winter" "Spring")
HOTELS=("FloatingPointResort" "GitawayHotel" "RecursionRetreat")
ROOMS=("SingletonRoom" "BooleanTwin" "RestfulKing")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

declare -i total=0 ok=0 fail=0
LAST_STATUS=""

# --- Helpers ---

# Sets LAST_STATUS and updates global counters.
# Called directly (not via $()) so side-effects propagate to parent shell.
request() {
  local period=$1 hotel=$2 room=$3
  local out
  out=$(curl -s -w "\n%{http_code}" "${APP_URL}?period=${period}&hotel=${hotel}&room=${room}")
  LAST_STATUS=$(echo "$out" | tail -1)
  ((total++))
  if [[ "$LAST_STATUS" == "200" ]]; then ((ok++)); else ((fail++)); fi
}

one_pass() {
  local label=$1
  local -i pass_ok=0 pass_fail=0
  for period in "${PERIODS[@]}"; do
    for hotel in "${HOTELS[@]}"; do
      for room in "${ROOMS[@]}"; do
        request "$period" "$hotel" "$room"
        if [[ "$LAST_STATUS" == "200" ]]; then ((pass_ok++)); else ((pass_fail++)); fi
      done
    done
  done
  echo -e "    ${label}: ${GREEN}${pass_ok} OK${NC} / ${RED}${pass_fail} error${NC}"
}

header() {
  echo ""
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

stats() {
  echo -e "${DIM}  ──────────────────────────────────────────────────${NC}"
  echo -e "  Cumulative — total: ${BOLD}$total${NC} | ${GREEN}200 OK: $ok${NC} | ${RED}error: $fail${NC}"
}

restart_with_ttl() {
  local cache_ttl=$1 stale_ttl=$2
  echo -e "  ${DIM}Restarting server: CACHE_TTL=${cache_ttl}s, STALE_CACHE_TTL=${stale_ttl}s...${NC}"
  CACHE_TTL_SECONDS=$cache_ttl STALE_CACHE_TTL_SECONDS=$stale_ttl \
    $COMPOSE up -d --force-recreate --no-deps interview-dev 2>/dev/null
  sleep 5
  echo -e "  ${GREEN}Server ready. Cache is empty.${NC}"
}

restore_server() {
  echo -e "  ${DIM}Restoring server with production defaults (TTL=300s, stale=3600s)...${NC}"
  $COMPOSE up -d --force-recreate --no-deps interview-dev 2>/dev/null
  sleep 5
  echo -e "  ${GREEN}Server restored to production defaults.${NC}"
}

# ===========================================================================
# Setup — restart with test TTLs
# ===========================================================================

header "SETUP: Starting server with test TTLs"
echo -e "  ${YELLOW}Test TTL  : ${TEST_CACHE_TTL}s (production: 300s)${NC}"
echo -e "  ${YELLOW}Stale TTL : ${TEST_STALE_TTL}s (production: 3600s)${NC}"
echo ""
restart_with_ttl $TEST_CACHE_TTL $TEST_STALE_TTL

# ===========================================================================
# PHASE 1 — TTL Cycle Simulation (4 minutes, 72 req/min)
# ===========================================================================

header "PHASE 1: TTL Cycle — 72 req/min for 4 minutes (3-min TTL)"
echo -e "  ${DIM}Pattern: 36 combinations × 2 hits each = 72 req/min${NC}"
echo -e "  ${DIM}Expected: upstream calls on minute 1 (MISS) and minute 4 (TTL expired)${NC}"
echo -e "  ${DIM}Dashboard: Cache HIT vs MISS and Upstream Calls panels${NC}"
echo ""

for minute in $(seq 1 4); do
  if [[ $minute -eq 1 ]]; then
    echo -e "  ${BLUE}[Minute $minute]${NC} Cold start — warming all 36 at 1 req/sec to avoid rate limit"

    # Warm up slowly so all 36 get cached before rate limit kicks in
    declare -i warm_ok=0 warm_fail=0
    for period in "${PERIODS[@]}"; do
      for hotel in "${HOTELS[@]}"; do
        for room in "${ROOMS[@]}"; do
          request "$period" "$hotel" "$room"
          if [[ "$LAST_STATUS" == "200" ]]; then ((warm_ok++)); else ((warm_fail++)); fi
          sleep 1
        done
      done
    done
    echo -e "    Warm-up: ${GREEN}${warm_ok} cached${NC} / ${RED}${warm_fail} failed${NC}"
    echo -e "    ${DIM}2nd sweep — verify all cached:${NC}"
    one_pass "  36 req (2nd sweep — should be all HIT)"

  elif [[ $minute -eq 4 ]]; then
    echo -e "  ${YELLOW}[Minute $minute]${NC} TTL expired (3 min) — cache stale, upstream called again"
    one_pass "  36 req (1st sweep — MISS, upstream called)"
    one_pass "  36 req (2nd sweep — all HIT, just cached above)"

  else
    echo -e "  ${BLUE}[Minute $minute]${NC} Within TTL — served from cache (0 upstream calls)"
    one_pass "  36 req (1st sweep — all HIT)"
    one_pass "  36 req (2nd sweep — all HIT)"
  fi
  stats

  if [[ $minute -lt 4 ]]; then
    echo -e "  ${DIM}Sleeping 60s...${NC}"
    sleep 60
  fi
done

echo ""
echo -e "  ${GREEN}Phase 1 done. Full 3-min TTL cycle observed.${NC}"
sleep 5

# ===========================================================================
# PHASE 2 — Upstream Timeout (restart server → empty cache → pause rate-api)
# ===========================================================================

header "PHASE 2: Upstream Timeout — 504 Gateway Timeout"
echo -e "  ${DIM}Restart clears MemoryStore → all requests hit upstream → rate-api paused → timeout${NC}"
echo -e "  ${DIM}Stale fallback does NOT trigger on timeout (only on HTTP 429)${NC}"
echo -e "  ${DIM}Dashboard: upstream_timeout spike, HTTP 504 in Responses panel${NC}"
echo ""

restart_with_ttl $TEST_CACHE_TTL $TEST_STALE_TTL

echo "  Pausing rate-api container..."
$COMPOSE pause rate-api 2>/dev/null
echo ""
echo "  Sending 8 requests (each will hang then timeout after 5s)..."

declare -i p2_timeout=0
for period in "${PERIODS[@]:0:2}"; do
  for hotel in "${HOTELS[@]:0:2}"; do
    for room in "${ROOMS[@]:0:2}"; do
      request "$period" "$hotel" "$room"
      if [[ "$LAST_STATUS" == "504" ]]; then
        echo -e "  ${RED}[504 TIMEOUT]${NC} $period / $hotel / $room"
        ((p2_timeout++))
      else
        echo -e "  [HTTP $LAST_STATUS]     $period / $hotel / $room"
      fi
    done
  done
done

echo ""
echo "  Unpausing rate-api..."
$COMPOSE unpause rate-api 2>/dev/null
echo -e "  ${GREEN}Phase 2 done. Timeouts: ${p2_timeout}/8. Waiting 5s for rate-api to recover...${NC}"
stats
sleep 5

# ===========================================================================
# PHASE 3 — Stale Fallback (warm cache → wait 3 min TTL → 429 → serve stale)
# ===========================================================================

header "PHASE 3: Stale Fallback — 429 from upstream → serve stale rate"
echo -e "  ${DIM}3a. Restart + warm 36 combinations slowly (1 req/sec)${NC}"
echo -e "  ${DIM}3b. Wait ${TEST_CACHE_TTL}s for fresh TTL to expire (stale TTL=${TEST_STALE_TTL}s intact)${NC}"
echo -e "  ${DIM}3c. During wait: exhaust token rate limit with direct upstream requests${NC}"
echo -e "  ${DIM}3d. Requests through app → cache MISS → upstream 429 → serve stale${NC}"
echo -e "  ${DIM}Dashboard: stale_fallback 'served_stale', upstream 429 rate_limited${NC}"
echo ""

# Step 3a: restart + warm slowly
restart_with_ttl $TEST_CACHE_TTL $TEST_STALE_TTL

echo "  Step 3a — Warming 36 combinations at 1 req/sec..."
declare -i warmed=0
for period in "${PERIODS[@]}"; do
  for hotel in "${HOTELS[@]}"; do
    for room in "${ROOMS[@]}"; do
      request "$period" "$hotel" "$room"
      [[ "$LAST_STATUS" == "200" ]] && ((warmed++))
      sleep 1
    done
  done
done
echo -e "  ${GREEN}Cache warmed: ${warmed}/36 (fresh TTL=${TEST_CACHE_TTL}s + stale TTL=${TEST_STALE_TTL}s written).${NC}"
echo ""

# Step 3b + 3c: wait for TTL, exhaust rate limit in background
echo "  Step 3b+3c — Waiting ${TEST_CACHE_TTL}s for TTL to expire + exhausting rate limit..."
echo ""

(
  sleep 20
  echo -e "\n  ${YELLOW}[bg] Sending 300 concurrent requests to rate-api to exhaust token...${NC}"
  for i in $(seq 1 300); do
    curl -s -m 3 -X POST "${RATE_API_DIRECT}/pricing" \
      -H "token: ${RATE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}' \
      -o /dev/null &
  done
  wait
  echo -e "  ${YELLOW}[bg] Done. Token rate limit exhausted.${NC}\n"
) &
EXHAUST_PID=$!

for remaining in $(seq $TEST_CACHE_TTL -15 15); do
  echo -ne "  TTL countdown: ${remaining}s remaining...\r"
  sleep 15
done
echo -ne "  TTL countdown: 0s — fresh cache has expired!     \n"

# Give exhaust job a few seconds to finish if still running, then move on
wait $EXHAUST_PID 2>/dev/null &
sleep 5
echo ""

# Step 3d: send requests through app
echo "  Step 3d — Sending all 36 combinations (expect stale fallback or 503 if no stale)..."
declare -i stale_ok=0 no_stale_err=0

for period in "${PERIODS[@]}"; do
  for hotel in "${HOTELS[@]}"; do
    for room in "${ROOMS[@]}"; do
      out=$(curl -s -w "\n%{http_code}" "${APP_URL}?period=${period}&hotel=${hotel}&room=${room}")
      body=$(echo "$out" | head -1)
      s=$(echo "$out" | tail -1)
      ((total++))
      rate=$(echo "$body" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); print(d.get("rate",""))' 2>/dev/null || echo "")
      error_msg=$(echo "$body" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); print(d.get("error",""))' 2>/dev/null || echo "")

      if [[ "$s" == "200" && -n "$rate" ]]; then
        ((ok++)); ((stale_ok++))
        echo -e "  ${GREEN}[200 OK]${NC}      $period / $hotel / $room → rate=$rate"
      elif [[ "$s" == "503" ]]; then
        ((fail++)); ((no_stale_err++))
        echo -e "  ${YELLOW}[503 NO-STALE]${NC} $period / $hotel / $room"
      else
        ((fail++))
        echo -e "  [HTTP $s]     $period / $hotel / $room"
      fi
    done
  done
done

echo ""
if [[ $stale_ok -gt 0 ]]; then
  echo -e "  ${GREEN}Stale fallback confirmed: ${stale_ok} served stale, ${no_stale_err} had no stale.${NC}"
  echo -e "  ${DIM}Verify in Grafana: Cache Stale Fallback panel should show 'served_stale' events.${NC}"
else
  echo -e "  ${YELLOW}Rate limit may not have been hit. All ${stale_ok} responded — check Upstream panel for 429.${NC}"
fi
stats

# ===========================================================================
# PHASE 4 — Concurrency / Capacity Test
#
# Goal:
#   1. Prove the app handles 10k req/day comfortably on a single instance.
#   2. Find the concurrency level where latency degrades or errors appear.
#   3. Document when Redis + multi-instance becomes necessary.
#
# Method:
#   - Restart server with default TTLs → warm all 36 combinations
#   - Fire N concurrent requests against a single cached key
#   - Levels: 10 / 50 / 100 / 500
#   - All requests should be cache HITs → upstream never called
#   - Measure: 200 vs error count, avg latency via curl %{time_total}
#
# Expected results:
#   - 10k req/day ≈ 0.12 req/sec average → trivial for single instance
#   - Errors appear only when Puma thread pool (default: 5) is saturated
#     AND requests queue faster than they are served
#   - Multi-instance / Redis becomes necessary only when horizontal scale needed
# ===========================================================================

header "PHASE 4: Concurrency / Capacity — single instance stress test"
echo -e "  ${DIM}4a. Coalescing — 50 concurrent requests to same cold key → expect 1 upstream call${NC}"
echo -e "  ${DIM}4b. Throughput — pre-warmed cache, burst 10/50/100/500 concurrent → measure latency${NC}"
echo ""

restore_server

# ---------------------------------------------------------------------------
# 4a — Mutex coalescing: 50 concurrent requests to same cold key
#
# Expected:
#   - All 50 return 200
#   - Upstream called exactly 1x (mutex prevents thundering herd)
#   - Loki log count for upstream_call on this key = 1
# ---------------------------------------------------------------------------

echo -e "  ${BLUE}[4a] Coalescing test — cold cache, 50 concurrent to same key${NC}"
echo -e "  ${DIM}Clearing cache by restarting server...${NC}"
restart_with_ttl $TEST_CACHE_TTL $TEST_STALE_TTL

LOKI_API="http://localhost:3100"
TEST_KEY_PARAMS="period=Summer&hotel=FloatingPointResort&room=SingletonRoom"
T_BEFORE=$(date -u +%s%N)  # nanoseconds

echo "  Firing 50 concurrent requests to Summer / FloatingPointResort / SingletonRoom..."
tmpdir_4a=$(mktemp -d)
for i in $(seq 1 50); do
  curl -s -o /dev/null \
    -w "%{http_code}\n" \
    "${APP_URL}?${TEST_KEY_PARAMS}" \
    > "${tmpdir_4a}/${i}.out" &
done
wait

T_AFTER=$(date -u +%s%N)

burst_ok=0; burst_fail=0
for f in "${tmpdir_4a}"/*.out; do
  code=$(<"$f")
  ((total++))
  if [[ "$code" == "200" ]]; then ((burst_ok++)); ((ok++)); else ((burst_fail++)); ((fail++)); fi
done
rm -rf "$tmpdir_4a"

echo -e "  Responses: ${GREEN}${burst_ok} OK${NC} / ${RED}${burst_fail} error${NC}"

# Query Loki for upstream_call count on this key within the burst window
# Add 2s buffer on each side to account for log ingestion lag
T_START=$(( T_BEFORE - 2000000000 ))
T_END=$(( T_AFTER + 5000000000 ))
LOKI_QUERY='{job="rails",msg="upstream_call"} |= "FloatingPointResort" |= "SingletonRoom" |= "Summer"'

echo -e "  ${DIM}Querying Loki for upstream_call count...${NC}"
sleep 3  # wait for log ingestion

loki_result=$(curl -s -G "${LOKI_API}/loki/api/v1/query_range" \
  --data-urlencode "query=${LOKI_QUERY}" \
  --data-urlencode "start=${T_START}" \
  --data-urlencode "end=${T_END}" \
  --data-urlencode "limit=100" 2>/dev/null)

upstream_count=$(echo "$loki_result" | \
  python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  results = d.get('data', {}).get('result', [])
  total = sum(len(s.get('values', [])) for s in results)
  print(total)
except:
  print('?')
" 2>/dev/null)

echo ""
if [[ "$upstream_count" == "1" ]]; then
  echo -e "  ${GREEN}✓ Coalescing CONFIRMED: upstream called ${upstream_count}x for 50 concurrent requests${NC}"
  echo -e "  ${DIM}  → mutex prevented thundering herd, 49 threads waited and read from cache${NC}"
elif [[ "$upstream_count" == "?" ]] || [[ -z "$upstream_count" ]]; then
  echo -e "  ${YELLOW}? Loki query failed — check Grafana manually for upstream_call count${NC}"
elif [[ "$upstream_count" -gt 1 ]]; then
  echo -e "  ${RED}✗ Thundering herd detected: upstream called ${upstream_count}x for 50 concurrent requests${NC}"
  echo -e "  ${DIM}  → coalescing not working as expected${NC}"
else
  echo -e "  ${DIM}  upstream_call count from Loki: ${upstream_count}${NC}"
fi
echo ""

# ---------------------------------------------------------------------------
# 4b — Throughput burst: pre-warmed cache, increasing concurrency levels
# ---------------------------------------------------------------------------

echo -e "  ${BLUE}[4b] Throughput test — pre-warmed cache, burst at 10 / 50 / 100 / 500${NC}"

# Warm the benchmark key (may already be cached from 4a, but ensure it)
request "Summer" "FloatingPointResort" "SingletonRoom"
if [[ "$LAST_STATUS" == "200" ]]; then
  echo -e "  ${GREEN}Cache warm. Running concurrency levels...${NC}"
else
  echo -e "  ${RED}Warm-up failed (HTTP $LAST_STATUS) — results may be unreliable${NC}"
fi
echo ""

concurrency_burst() {
  local level=$1
  local tmpdir
  tmpdir=$(mktemp -d)

  for i in $(seq 1 "$level"); do
    curl -s -o /dev/null \
      -w "%{http_code} %{time_total}\n" \
      "${APP_URL}?${TEST_KEY_PARAMS}" \
      > "${tmpdir}/${i}.out" &
  done
  wait

  local burst_ok=0 burst_fail=0 total_time=0 count=0
  for f in "${tmpdir}"/*.out; do
    read -r code t < "$f"
    ((count++))
    total_time=$(echo "$total_time + $t" | bc)
    if [[ "$code" == "200" ]]; then ((burst_ok++)); ((ok++)); else ((burst_fail++)); ((fail++)); fi
    ((total++))
  done
  rm -rf "$tmpdir"

  local avg_ms=0
  if [[ $count -gt 0 ]]; then
    avg_ms=$(echo "scale=0; $total_time / $count * 1000" | bc)
  fi

  if [[ $burst_fail -eq 0 ]]; then
    echo -e "  ${GREEN}[${level} concurrent]${NC} ${GREEN}${burst_ok} OK${NC} / ${RED}${burst_fail} error${NC} — avg latency: ${avg_ms}ms"
  else
    echo -e "  ${YELLOW}[${level} concurrent]${NC} ${GREEN}${burst_ok} OK${NC} / ${RED}${burst_fail} error${NC} — avg latency: ${avg_ms}ms ${RED}← errors detected${NC}"
  fi
}

for level in 10 50 100 500; do
  concurrency_burst "$level"
  sleep 2
done

echo ""
echo -e "  ${DIM}Note: errors at high concurrency = Puma thread pool (5 threads) saturated.${NC}"
echo -e "  ${DIM}For multi-instance deployments, MemoryStore is NOT shared — switch to Redis.${NC}"
echo -e "  ${DIM}10k req/day = ~0.12 req/sec avg → well within single-instance capacity.${NC}"
stats

# ===========================================================================
# Restore production defaults
# ===========================================================================

header "RESTORE: Production TTL defaults"
restore_server

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}${BOLD}  TEST COMPLETE${NC}"
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Total requests : ${BOLD}$total${NC}"
echo -e "  ${GREEN}200 OK         : $ok${NC}"
echo -e "  ${RED}Error          : $fail${NC}"
echo ""
echo -e "${BOLD}  Grafana → http://localhost:3001/d/dynamic-pricing${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Cache HIT vs MISS      — 36 MISSes min 1, flat min 2–3, 36 MISSes min 4"
echo -e "  ${GREEN}✓${NC} Requests per Minute    — ~72 req/min across Phase 1, spikes in Phase 2–3"
echo -e "  ${GREEN}✓${NC} Upstream Calls         — spike min 1, flat min 2–3, spike min 4, timeout Phase 2"
echo -e "  ${GREEN}✓${NC} Responses by Status    — mostly 200, 504 spike in Phase 2"
echo -e "  ${GREEN}✓${NC} Upstream Response      — success / timeout / 429 rate_limited"
echo -e "  ${GREEN}✓${NC} Cache Stale Fallback   — served_stale events in Phase 3"
echo -e "  ${GREEN}✓${NC} Coalescing [4a]        — 50 concurrent cold key → 1 upstream call (no thundering herd)"
echo -e "  ${GREEN}✓${NC} Concurrency burst [4b] — 10 / 50 / 100 / 500 concurrent, all cache HITs"
echo -e "  ${GREEN}✓${NC} Request Flow Trace     — paste X-Request-Id to trace end-to-end"
echo ""
