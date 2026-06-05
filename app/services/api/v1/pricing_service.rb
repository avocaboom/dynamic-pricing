module Api::V1
  class PricingService < BaseService
    CACHE_TTL       = 5.minutes
    STALE_CACHE_TTL = 1.hour

    RateLimitError = Class.new(StandardError)

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      cache_key = "pricing/v1/#{@period}/#{@hotel}/#{@room}"
      stale_key = "pricing/v1/stale/#{@period}/#{@hotel}/#{@room}"
      cache_hit = true

      @result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        cache_hit = false
        log_info(event: "pricing_cache", cache: "MISS")
        rate = fetch_from_upstream
        Rails.cache.write(stale_key, rate, expires_in: STALE_CACHE_TTL)
        log_info(event: "cache_write", fresh_ttl_s: CACHE_TTL.to_i, stale_ttl_s: STALE_CACHE_TTL.to_i)
        rate
      end

      log_info(event: "pricing_cache", cache: "HIT") if cache_hit
    rescue RateLimitError
      stale = Rails.cache.read(stale_key)
      if stale
        @result = stale
        @served_stale = true
        log_warn(event: "stale_fallback", action: "served_stale")
      else
        self.http_status = :service_unavailable
        errors << "Pricing service rate limit reached and no cached data available. Please try again later."
        log_error(event: "stale_fallback", action: "no_stale_available")
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      self.http_status = :gateway_timeout
      errors << "Pricing service timed out. Please try again later."
      log_error(event: "upstream_timeout")
    rescue => e
      self.http_status = :service_unavailable
      errors << "Pricing service is currently unavailable. Please try again later."
      log_error(event: "upstream_error", error_class: e.class.name, message: e.message)
    end

    def served_stale?
      @served_stale || false
    end

    private

    def fetch_from_upstream
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

      raise RateLimitError, "HTTP 429" if response.code == 429
      raise "Upstream error (HTTP #{response.code})" unless response.success?

      parsed = JSON.parse(response.body)
      rate = parsed['rates']
        &.detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
        &.dig('rate')

      raise "Rate not found for the given parameters" if rate.nil?

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      log_info(event: "upstream_call", status: "success", duration_ms: duration_ms, rate: rate)
      rate
    rescue RateLimitError
      log_warn(event: "upstream_call", status: "rate_limited")
      raise
    rescue JSON::ParserError => e
      raise "Upstream returned a malformed response: #{e.message}"
    end

    def build_log_payload(level, extra)
      event = extra.delete(:event)
      {
        request_id: Thread.current[:request_id],
        time:       Time.now.utc.iso8601(3),
        level:      level,
        msg:        event,
        period:     @period,
        hotel:      @hotel,
        room:       @room
      }.merge(extra).compact
    end

    def log_info(payload)  = Rails.logger.info(build_log_payload("info",  payload).to_json)
    def log_warn(payload)  = Rails.logger.warn(build_log_payload("warn",  payload).to_json)
    def log_error(payload) = Rails.logger.error(build_log_payload("error", payload).to_json)
  end
end
