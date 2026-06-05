require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    ActionController::Base.perform_caching = false
  end

  # --- Existing: basic response ---

  test "should get pricing with all parameters" do
    RateApiClient.stub(:get_rate, success_response) do
      get api_v1_pricing_url, params: valid_params
      assert_response :success
      assert_equal "application/json", @response.media_type
      assert_equal "15000", json_response["rate"]
    end
  end

  # --- Input validation ---

  test "should return error without any parameters" do
    get api_v1_pricing_url
    assert_response :bad_request
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }
    assert_response :bad_request
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: valid_params.merge(period: "summer-2024")
    assert_response :bad_request
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: valid_params.merge(hotel: "InvalidHotel")
    assert_response :bad_request
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: valid_params.merge(room: "InvalidRoom")
    assert_response :bad_request
    assert_includes json_response["error"], "Invalid room"
  end

  # --- Cache behavior ---

  test "calls upstream on first request (cache MISS)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params
    end
    assert_equal 1, call_count
  end

  test "does not call upstream on second request with same params (cache HIT)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      2.times { get api_v1_pricing_url, params: valid_params }
    end
    assert_equal 1, call_count
  end

  test "calls upstream separately for different params (cache isolation)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params
      get api_v1_pricing_url, params: valid_params.merge(room: "BooleanTwin")
    end
    assert_equal 2, call_count
  end

  test "does not call upstream within TTL window (cache still valid before TTL expires)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params

      travel(Api::V1::PricingService::CACHE_TTL - 1.minute) do
        get api_v1_pricing_url, params: valid_params
      end
    end
    assert_equal 1, call_count
  end

  test "calls upstream again after cache expires (after 5-minute TTL)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params

      travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
        get api_v1_pricing_url, params: valid_params
      end
    end
    assert_equal 2, call_count
  end

  test "returns same rate on cache HIT" do
    RateApiClient.stub(:get_rate, success_response) do
      2.times { get api_v1_pricing_url, params: valid_params }
      assert_equal "15000", json_response["rate"]
    end
  end

  # --- Error handling ---

  test "returns 503 when upstream is unavailable and no stale exists" do
    mock_error = OpenStruct.new(success?: false, code: 503, body: { "error" => "Service error" })
    RateApiClient.stub(:get_rate, mock_error) do
      get api_v1_pricing_url, params: valid_params
      assert_response :service_unavailable
      assert json_response["error"].present?
    end
  end

  test "returns stale rate when upstream is unavailable and stale exists" do
    RateApiClient.stub(:get_rate, success_response) do
      get api_v1_pricing_url, params: valid_params
    end

    mock_error = OpenStruct.new(success?: false, code: 503, body: "")
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, mock_error) do
        get api_v1_pricing_url, params: valid_params
        assert_response :success
        assert_equal "15000", json_response["rate"]
      end
    end
  end

  test "returns 504 when upstream times out and no stale exists" do
    RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
      get api_v1_pricing_url, params: valid_params
      assert_response :gateway_timeout
      assert_includes json_response["error"], "timed out"
    end
  end

  test "returns stale rate when upstream times out and stale exists" do
    RateApiClient.stub(:get_rate, success_response) do
      get api_v1_pricing_url, params: valid_params
    end

    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
        get api_v1_pricing_url, params: valid_params
        assert_response :success
        assert_equal "15000", json_response["rate"]
      end
    end
  end

  test "returns 504 for all valid param combinations when upstream times out and no cache exists" do
    periods = %w[Summer Autumn Winter Spring]
    hotels  = %w[FloatingPointResort GitawayHotel RecursionRetreat]
    rooms   = %w[SingletonRoom BooleanTwin RestfulKing]

    periods.each do |period|
      hotels.each do |hotel|
        rooms.each do |room|
          Rails.cache.clear
          RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
            get api_v1_pricing_url, params: { period: period, hotel: hotel, room: room }
            assert_response :gateway_timeout,
              "Expected 504 for (#{period}, #{hotel}, #{room}), got #{@response.status}"
            assert_includes json_response["error"], "timed out",
              "Expected 'timed out' in error for (#{period}, #{hotel}, #{room})"
          end
        end
      end
    end
  end

  test "returns error when upstream returns malformed JSON" do
    malformed = OpenStruct.new(success?: true, body: "not valid json{{{")
    RateApiClient.stub(:get_rate, malformed) do
      get api_v1_pricing_url, params: valid_params
      assert_response :service_unavailable
      assert json_response["error"].present?
    end
  end

  test "returns error when rate not found in upstream response" do
    empty_rates = OpenStruct.new(success?: true, body: { "rates" => [] }.to_json)
    RateApiClient.stub(:get_rate, empty_rates) do
      get api_v1_pricing_url, params: valid_params
      assert_response :service_unavailable
      assert json_response["error"].present?
    end
  end

  # --- Rate limit handling ---

  test "returns stale rate when upstream hits rate limit and stale cache exists" do
    # First request populates both fresh and stale cache
    RateApiClient.stub(:get_rate, ->(*) { success_response }) do
      get api_v1_pricing_url, params: valid_params
    end

    # After TTL, fresh cache expires — upstream returns 429
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    travel(Api::V1::PricingService::CACHE_TTL + 1.minute) do
      RateApiClient.stub(:get_rate, rate_limited) do
        get api_v1_pricing_url, params: valid_params
        assert_response :success
        assert_equal "15000", json_response["rate"]
      end
    end
  end

  test "returns 503 when upstream hits rate limit and no stale cache exists" do
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    RateApiClient.stub(:get_rate, rate_limited) do
      get api_v1_pricing_url, params: valid_params
      assert_response :service_unavailable
      assert json_response["error"].present?
    end
  end

  test "returns 503 when upstream hits rate limit and stale cache has also expired" do
    # Populate fresh + stale cache
    RateApiClient.stub(:get_rate, ->(*) { success_response }) do
      get api_v1_pricing_url, params: valid_params
    end

    # Travel past both fresh TTL (5 min) and stale TTL (1 hour)
    rate_limited = OpenStruct.new(success?: false, code: 429, body: "")
    travel(Api::V1::PricingService::STALE_CACHE_TTL + 6.minutes) do
      RateApiClient.stub(:get_rate, rate_limited) do
        get api_v1_pricing_url, params: valid_params
        assert_response :service_unavailable
        assert json_response["error"].present?
      end
    end
  end

  private

  def valid_params
    { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
  end

  def success_response
    body = { "rates" => [{ "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }] }.to_json
    OpenStruct.new(success?: true, body: body)
  end

  def json_response
    JSON.parse(@response.body)
  end
end
