module EmailIdentities
  # SMTP例外や任意metadata中の宛先も対象にし、構造化キーのfilter漏れを補う。
  class Redactor
    EMAIL_PATTERN = /[^\s<>"'()]+@[^\s<>"'()]+/

    def self.call(value)
      value.to_s.gsub(EMAIL_PATTERN, "[FILTERED_EMAIL]")
    end
  end
end
