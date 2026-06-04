class BaseService
  attr_accessor :result

  def valid?
    errors.blank?
  end

  def errors
    @errors ||= []
  end

  def http_status
    @http_status ||= :bad_request
  end

  def http_status=(status)
    @http_status = status
  end
end
