module SystemEvents
  class Sanitizer
    FILTERED = "[FILTERED]"
    SENSITIVE_KEY_PATTERN = %r{
      authorization|cookie|session|token|access[_-]?token|refresh[_-]?token|password|secret|
      api[_-]?key|smtp|database[_-]?url|magic[_-]?link|csrf
    }ix
    ABSOLUTE_PATH_PATTERN = %r{(?:/Users|/home|/private|/var|/tmp)/[^\s:,;]+}

    def initialize(value)
      @value = value
    end

    def call
      sanitize(@value.to_h.deep_stringify_keys)
    end

    def self.safe_error_message(error)
      error.message.to_s.gsub(ABSOLUTE_PATH_PATTERN, "[FILTERED_PATH]").first(500)
    end

    private

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          result[key] = key.match?(SENSITIVE_KEY_PATTERN) ? FILTERED : sanitize(nested_value)
        end
      when Array
        value.map { |nested_value| sanitize(nested_value) }
      when String
        value.gsub(ABSOLUTE_PATH_PATTERN, "[FILTERED_PATH]").first(2_000)
      else
        value
      end
    end
  end
end
