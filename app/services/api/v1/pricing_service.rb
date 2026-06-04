module Api::V1
  class PricingService < BaseService
    CACHE_TTL = 5.minutes

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      cache_key = "pricing/v1/#{@period}/#{@hotel}/#{@room}"
      @result = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        fetch_from_upstream
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      self.http_status = :gateway_timeout
      errors << "Pricing service timed out. Please try again later."
    rescue => e
      self.http_status = :service_unavailable
      errors << "Pricing service is currently unavailable. Please try again later."
      Rails.logger.error({ event: "pricing_upstream_error", error_class: e.class.name, message: e.message, period: @period, hotel: @hotel, room: @room }.to_json)
    end

    private

    def fetch_from_upstream
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

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
