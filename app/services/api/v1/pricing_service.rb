module Api::V1
  class PricingService < BaseService
    CACHE_TTL       = 5.minutes
    # How long to retain a stale copy as fallback when upstream hits rate limit.
    # Exact value should be decided based on business tolerance for stale pricing data.
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

      @result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        rate = fetch_from_upstream
        Rails.cache.write(stale_key, rate, expires_in: STALE_CACHE_TTL)
        rate
      end
    rescue RateLimitError
      stale = Rails.cache.read(stale_key)
      if stale
        @result = stale
        @served_stale = true
      else
        self.http_status = :service_unavailable
        errors << "Pricing service rate limit reached and no cached data available. Please try again later."
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      self.http_status = :gateway_timeout
      errors << "Pricing service timed out. Please try again later."
    rescue => e
      self.http_status = :service_unavailable
      errors << "Pricing service is currently unavailable. Please try again later."
      Rails.logger.error({ event: "pricing_upstream_error", error_class: e.class.name, message: e.message, period: @period, hotel: @hotel, room: @room }.to_json)
    end

    def served_stale?
      @served_stale || false
    end

    private

    def fetch_from_upstream
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

      raise RateLimitError if response.code == 429
      raise "Upstream error (HTTP #{response.code})" unless response.success?

      parsed = JSON.parse(response.body)
      rate = parsed['rates']
        &.detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
        &.dig('rate')

      raise "Rate not found for the given parameters" if rate.nil?

      rate
    rescue JSON::ParserError => e
      raise "Upstream returned a malformed response: #{e.message}"
    end
  end
end
