require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true

    Thread.current[:request_id] = "test-request-id"

    @log_output = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = Logger.new(@log_output)
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    ActionController::Base.perform_caching = false
    Thread.current[:request_id] = nil
    Rails.logger = @original_logger
  end

  # --- request_id propagation ---

  test "includes request_id in every log line" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"request_id":"test-request-id"')
  end

  # --- Cache HIT / MISS logging ---

  test "logs cache MISS on first request" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"msg":"pricing_cache"')
    assert_log_contains('"cache":"MISS"')
  end

  test "logs cache HIT on second request with same params" do
    RateApiClient.stub(:get_rate, success_response) do
      2.times { run_service }
    end
    assert_log_contains('"cache":"HIT"')
  end

  test "logs upstream_call start and success on cache MISS" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"msg":"upstream_call"')
    assert_log_contains('"status":"success"')
    assert_log_contains('"duration_ms"')
    assert_log_contains('"rate":"15000"')
  end

  test "logs cache_write after upstream success" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end
    assert_log_contains('"msg":"cache_write"')
    assert_log_contains("\"fresh_ttl_s\":#{Api::V1::PricingService::CACHE_TTL.to_i}")
  end

  # --- Stale fallback logging ---

  test "logs stale_fallback served_stale when 429 and stale exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, rate_limited) do
        run_service
      end
    end

    assert_log_contains('"msg":"stale_fallback"')
    assert_log_contains('"action":"served_stale"')
  end

  test "logs stale_fallback no_stale_available when 429 and no stale" do
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    RateApiClient.stub(:get_rate, rate_limited) do
      run_service
    end

    assert_log_contains('"msg":"stale_fallback"')
    assert_log_contains('"action":"no_stale_available"')
  end

  test "logs upstream_call rate_limited on 429" do
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    RateApiClient.stub(:get_rate, rate_limited) do
      run_service
    end
    assert_log_contains('"status":"rate_limited"')
  end

  # --- Stale fallback behavior ---

  test "serves stale rate when upstream hits rate limit and stale cache exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    service = nil
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, rate_limited) do
        service = build_service
        service.run
      end
    end

    assert service.valid?, "service should be valid when serving stale"
    assert_equal "15000", service.result, "should return the cached stale rate"
    assert service.served_stale?, "served_stale? should be true"
  end

  test "stale value matches the original successful rate" do
    first_body = { "rates" => [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "99999" }] }.to_json
    first_response = OpenStruct.new(success?: true, body: first_body)

    RateApiClient.stub(:get_rate, first_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    service = nil
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, rate_limited) do
        service = build_service
        service.run
      end
    end

    assert_equal "99999", service.result, "stale result must match what was originally cached"
  end

  test "is invalid with 503 status when rate limited and no stale cache exists" do
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    service = build_service
    RateApiClient.stub(:get_rate, rate_limited) do
      service.run
    end

    refute service.valid?
    assert_equal :service_unavailable, service.http_status
    assert service.errors.any?
  end

  test "is invalid with 503 status when rate limited and stale cache has expired" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    service = nil
    travel(Api::V1::PricingService::STALE_CACHE_TTL + 6.minutes) do
      RateApiClient.stub(:get_rate, rate_limited) do
        service = build_service
        service.run
      end
    end

    refute service.valid?
    assert_equal :service_unavailable, service.http_status
  end

  # --- Upstream error logging ---

  test "logs upstream_timeout on ReadTimeout" do
    RateApiClient.stub(:get_rate, -> (*) { raise Net::ReadTimeout }) do
      run_service
    end
    assert_log_contains('"msg":"upstream_timeout"')
  end

  test "logs upstream_error with error_class on upstream failure" do
    mock_error = OpenStruct.new(success?: false, code: 503, body: "")
    RateApiClient.stub(:get_rate, mock_error) do
      run_service
    end
    assert_log_contains('"msg":"upstream_error"')
    assert_log_contains('"error_class"')
  end

  # --- Upstream timeout behavior ---

  test "is invalid with 504 status on Net::ReadTimeout when no stale exists" do
    service = build_service
    RateApiClient.stub(:get_rate, -> (*) { raise Net::ReadTimeout }) do
      service.run
    end

    refute service.valid?
    assert_equal :gateway_timeout, service.http_status
    assert_includes service.errors.first, "timed out"
  end

  test "is invalid with 504 status on Net::OpenTimeout when no stale exists" do
    service = build_service
    RateApiClient.stub(:get_rate, -> (*) { raise Net::OpenTimeout }) do
      service.run
    end

    refute service.valid?
    assert_equal :gateway_timeout, service.http_status
    assert_includes service.errors.first, "timed out"
  end

  test "serves stale on Net::ReadTimeout when stale cache exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    service = nil
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, -> (*) { raise Net::ReadTimeout }) do
        service = build_service
        service.run
      end
    end

    assert service.valid?, "should serve stale when timeout and stale exists"
    assert_equal "15000", service.result
    assert service.served_stale?
  end

  test "serves stale on upstream error (non-429, non-timeout) when stale cache exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    mock_error = OpenStruct.new(success?: false, code: 503, body: "")
    service = nil
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, mock_error) do
        service = build_service
        service.run
      end
    end

    assert service.valid?, "should serve stale when upstream 503 and stale exists"
    assert_equal "15000", service.result
    assert service.served_stale?
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
    build_service.run
  end

  def build_service
    Api::V1::PricingService.new(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
  end

  def success_response
    body = { "rates" => [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }] }.to_json
    OpenStruct.new(success?: true, body: body)
  end

  def assert_log_contains(text)
    assert_includes @log_output.string, text, "Expected log to contain: #{text}\nActual log:\n#{@log_output.string}"
  end
end
