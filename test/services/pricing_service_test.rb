require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true

    @log_output = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = Logger.new(@log_output)
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    ActionController::Base.perform_caching = false
    Rails.logger = @original_logger
  end

  # --- Cache HIT / MISS logging ---

  test "logs cache MISS on first request" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"cache":"MISS"')
  end

  test "logs cache HIT on second request with same params" do
    RateApiClient.stub(:get_rate, success_response) do
      2.times { run_service }
    end
    assert_log_contains('"cache":"HIT"')
  end

  test "logs event pricing_cache on every request" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"event":"pricing_cache"')
  end

  # --- Rate limit logging ---

  test "logs warn with served_stale when 429 and stale cache exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    travel 6.minutes do
      RateApiClient.stub(:get_rate, rate_limited) do
        run_service
      end
    end

    assert_log_contains('"event":"pricing_rate_limit"')
    assert_log_contains('"action":"served_stale"')
  end

  test "logs error with no_stale_available when 429 and no stale cache" do
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    RateApiClient.stub(:get_rate, rate_limited) do
      run_service
    end

    assert_log_contains('"event":"pricing_rate_limit"')
    assert_log_contains('"action":"no_stale_available"')
  end

  # --- Upstream error logging ---

  test "logs upstream timeout error" do
    RateApiClient.stub(:get_rate, -> (*) { raise Net::ReadTimeout }) do
      run_service
    end
    assert_log_contains('"event":"pricing_upstream_timeout"')
  end

  test "logs upstream error with error_class and message" do
    mock_error = OpenStruct.new(success?: false, code: 503, body: "")
    RateApiClient.stub(:get_rate, mock_error) do
      run_service
    end
    assert_log_contains('"event":"pricing_upstream_error"')
    assert_log_contains('"error_class"')
  end

  # --- Token safety ---

  test "API token does not appear in log output" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    token = ENV.fetch("RATE_API_TOKEN", "04aa6f42aa03f220c2ae9a276cd68c62")
    refute_includes @log_output.string, token
  end

  private

  def run_service
    Api::V1::PricingService.new(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom").run
  end

  def success_response
    body = { "rates" => [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }] }.to_json
    OpenStruct.new(success?: true, body: body)
  end

  def assert_log_contains(text)
    assert_includes @log_output.string, text, "Expected log to contain: #{text}\nActual log:\n#{@log_output.string}"
  end
end
