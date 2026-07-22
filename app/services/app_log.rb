# frozen_string_literal: true

# Structured, operator-friendly logging for docker compose logs -f.
# Format: [component] event key=value key=value
module AppLog
  module_function

  def info(component, event, **fields)
    write(:info, component, event, **fields)
  end

  def warn(component, event, **fields)
    write(:warn, component, event, **fields)
  end

  def error(component, event, **fields)
    write(:error, component, event, **fields)
  end

  def write(level, component, event, **fields)
    message = format(component, event, **fields)
    Rails.logger.public_send(level, message)
    # Ensure one-shot CLI tasks surface the same lines on stdout even if logger is buffered.
    $stdout.puts(message) if ENV["APP_LOG_MIRROR_STDOUT"] == "1"
  end

  def format(component, event, **fields)
    parts = fields.map { |key, value| "#{key}=#{sanitize(value)}" }
    "[#{component}] #{event}#{parts.empty? ? "" : " #{parts.join(" ")}"}"
  end

  def sanitize(value)
    case value
    when nil then "nil"
    when String, Symbol, Numeric, TrueClass, FalseClass then value.inspect
    else value.to_s.inspect
    end
  end
end
