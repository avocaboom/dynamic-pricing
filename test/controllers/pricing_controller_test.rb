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

  test "does not call upstream within TTL window (cache still valid at 4 minutes)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params

      travel 4.minutes do
        get api_v1_pricing_url, params: valid_params
      end
    end
    assert_equal 1, call_count
  end

  test "calls upstream again after cache expires (after 5-minute TTL)" do
    call_count = 0
    RateApiClient.stub(:get_rate, ->(*) { call_count += 1; success_response }) do
      get api_v1_pricing_url, params: valid_params

      travel 6.minutes do
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

  test "returns 503 when upstream is unavailable" do
    mock_error = OpenStruct.new(success?: false, code: 503, body: { "error" => "Service error" })
    RateApiClient.stub(:get_rate, mock_error) do
      get api_v1_pricing_url, params: valid_params
      assert_response :service_unavailable
      assert json_response["error"].present?
    end
  end

  test "returns 504 when upstream times out" do
    RateApiClient.stub(:get_rate, ->(*) { raise Net::ReadTimeout }) do
      get api_v1_pricing_url, params: valid_params
      assert_response :gateway_timeout
      assert_includes json_response["error"], "timed out"
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
