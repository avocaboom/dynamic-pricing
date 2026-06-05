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
    assert_log_contains('"fresh_ttl_s":300')
  end

  # --- Stale fallback logging ---

  test "logs stale_fallback served_stale when 429 and stale exists" do
    RateApiClient.stub(:get_rate, success_response) do
      run_service
    end

    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    travel 6.minutes do
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
