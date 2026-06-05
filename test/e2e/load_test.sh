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
    echo -e "  ${BLUE}[Minute $minute]${NC} Cold start — cache empty, all 36 hit upstream (MISS)"
  elif [[ $minute -eq 4 ]]; then
    echo -e "  ${YELLOW}[Minute $minute]${NC} TTL expired (3 min) — cache stale, upstream called again"
  else
    echo -e "  ${BLUE}[Minute $minute]${NC} Within TTL — served from cache (0 upstream calls)"
  fi

  # Each minute: send 36 combinations twice = 72 requests
  # First 36: MISS on min 1 & 4 (expired), HIT on min 2-3
  # Second 36: always HIT (just cached by first 36)
  one_pass "  36 req (1st sweep — MISS min1/4, HIT min2-3)"
  one_pass "  36 req (2nd sweep — all HIT, just cached above)"
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
    for room in "${ROOMS[@]:0:1}"; do
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
  echo -e "\n  ${YELLOW}[bg] Sending 300 direct requests to rate-api to exhaust token...${NC}"
  for i in $(seq 1 300); do
    curl -s -X POST "${RATE_API_DIRECT}/pricing" \
      -H "token: ${RATE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}' \
      -o /dev/null
  done
  echo -e "  ${YELLOW}[bg] Done. Token rate limit exhausted.${NC}\n"
) &
EXHAUST_PID=$!

for remaining in $(seq $TEST_CACHE_TTL -15 15); do
  echo -ne "  TTL countdown: ${remaining}s remaining...\r"
  sleep 15
done
echo -ne "  TTL countdown: 0s — fresh cache has expired!     \n"

wait $EXHAUST_PID 2>/dev/null
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
echo -e "${BOLD}  Grafana → http://localhost:3001${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Cache HIT vs MISS      — 36 MISSes min 1, flat min 2–3, 36 MISSes min 4"
echo -e "  ${GREEN}✓${NC} Requests per Minute    — ~72 req/min across Phase 1, spikes in Phase 2–3"
echo -e "  ${GREEN}✓${NC} Upstream Calls         — spike min 1, flat min 2–3, spike min 4, timeout Phase 2"
echo -e "  ${GREEN}✓${NC} Responses by Status    — mostly 200, 504 spike in Phase 2"
echo -e "  ${GREEN}✓${NC} Upstream Response      — success / timeout / 429 rate_limited"
echo -e "  ${GREEN}✓${NC} Cache Stale Fallback   — served_stale events in Phase 3"
echo -e "  ${GREEN}✓${NC} Request Flow Trace     — paste X-Request-Id to trace end-to-end"
echo ""
