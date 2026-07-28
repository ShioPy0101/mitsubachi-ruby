module OperationLogs
  class Sanitizer
    SENSITIVE_KEY_PATTERN = /(authorization|cookie|session|token|password|secret|api.?key|csrf)/i

    def initialize(value)
      @value = value
    end

    def call
      sanitize(@value.to_h.deep_stringify_keys)
    end

    private

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          next if key.match?(SENSITIVE_KEY_PATTERN)

          result[key] = sanitize(nested_value)
        end
      when Array
        value.map { |nested_value| sanitize(nested_value) }
      else
        value
      end
    end
  end
end
