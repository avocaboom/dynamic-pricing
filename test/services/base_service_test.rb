require "test_helper"

class BaseServiceTest < ActiveSupport::TestCase
  test "http_status defaults to :bad_request" do
    service = BaseService.new
    assert_equal :bad_request, service.http_status
  end

  test "http_status can be overridden" do
    service = BaseService.new
    service.http_status = :service_unavailable
    assert_equal :service_unavailable, service.http_status
  end
end
