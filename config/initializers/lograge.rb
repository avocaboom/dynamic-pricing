Rails.application.configure do
  config.lograge.enabled = true

  # Custom formatter — keeps only the fields that matter for operations:
  # request_id first (for log correlation), then standard request fields.
  # Drops Lograge defaults that add noise: format, controller, action, allocations, view, db.
  config.lograge.formatter = Class.new do
    FIELD_ORDER = %w[request_id time level msg method path status duration params].freeze

    def call(data)
      ordered = {}
      FIELD_ORDER.each do |key|
        sym = key.to_sym
        ordered[sym] = data[sym] if data.key?(sym)
      end
      ordered.to_json
    end
  end.new

  # Add request_id, timestamp, level, and msg — request_id goes first via FIELD_ORDER above.
  config.lograge.custom_options = lambda do |event|
    request_id = event.payload[:headers]&.env&.dig("action_dispatch.request_id")
    status = event.payload[:status].to_i
    level  = status >= 500 ? "error" : status >= 400 ? "warn" : "info"
    opts = { request_id: request_id, time: Time.now.utc.iso8601(3), level: level, msg: "request" }
    params = event.payload[:params]&.except("controller", "action", "format")
    opts[:params] = params if params&.any?
    opts
  end
end
