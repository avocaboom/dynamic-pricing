# Design: Dynamic Pricing Proxy

## Current Flow (Before Caching)

```
┌─────────────────────────────────────────────────────────────────┐
│  CLIENT                                                         │
│  GET /api/v1/pricing?period=Summer&hotel=...&room=...           │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  ROUTER  config/routes.rb                                       │
│  → Api::V1::PricingController#index                             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  BEFORE ACTION  validate_params                                 │
│                                                                 │
│  period ∈ [Summer, Autumn, Winter, Spring]?  ──── NO ──→ 400   │
│  hotel  ∈ [FloatingPointResort, ...]?        ──── NO ──→ 400   │
│  room   ∈ [SingletonRoom, ...]?              ──── NO ──→ 400   │
│                           │                                     │
│                          YES                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  PricingController#index                                        │
│  service = Api::V1::PricingService.new(period:, hotel:, room:)  │
│  service.run                                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Api::V1::PricingService#run                                    │
│                                                                 │
│  ⚠️  CURRENT: hits upstream on every single request              │
│                                                                 │
│  RateApiClient.get_rate(period:, hotel:, room:)                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  RateApiClient  lib/rate_api_client.rb                          │
│                                                                 │
│  POST http://rate-api:8080/pricing                              │
│  headers: { token: "04aa6f42..." }                              │
│  body:    { attributes: [{ period, hotel, room }] }             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  tripladev/rate-api  (Docker container :8080)                   │
│                                                                 │
│  Runs expensive ML pricing model                                │
│  Returns: { rates: [{ period, hotel, room, rate: "15000" }] }   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  PricingService  (parsing)                                      │
│                                                                 │
│  rates.detect { period == p && hotel == h && room == r }        │
│  → extract "rate" value                                         │
│                           │                                     │
│              success?     │      failed?                        │
│                 │         │         │                           │
│                 ▼         │         ▼                           │
│          @result = rate   │   errors << message                 │
└──────────┬────────────────┴──────────┬──────────────────────────┘
           │                           │
           ▼                           ▼
    { "rate": "15000" }         { "error": "..." }
         200 OK                    400 Bad Request
```

## Target Flow (After Caching)

The change happens inside `PricingService#run`, between the controller call and RateApiClient:

```
PricingController#index
       │
       ▼
Api::V1::PricingService#run
       │
       ▼
  cache_key = "pricing/v1/{period}/{hotel}/{room}"
       │
       ▼
  Rails.cache.read(cache_key)
       │
  ┌────┴────┐
 HIT       MISS
  │         │
  ▼         ▼
return    RateApiClient.get_rate
cached      │
rate        ▼
          parse response
            │
        ┌───┴───┐
      success  error
        │         │
        ▼         ▼
  Rails.cache   errors <<
  .write(key,   message
   rate,
   expires_in: 5.minutes)
        │
        ▼
    @result = rate
```
