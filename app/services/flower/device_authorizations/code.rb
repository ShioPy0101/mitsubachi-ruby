module Flower
  module DeviceAuthorizations
    module Code
      USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".freeze

      module_function

      def device_code
        SecureRandom.urlsafe_base64(48)
      end

      def user_code
        raw = Array.new(8) { USER_CODE_ALPHABET[SecureRandom.random_number(USER_CODE_ALPHABET.length)] }.join
        "#{raw.first(4)}-#{raw.last(4)}"
      end

      def normalize_user_code(value)
        value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      end

      def user_code_digest(value)
        Flower::Tokens::Codec.digest(normalize_user_code(value))
      end

      def device_code_digest(value)
        Flower::Tokens::Codec.digest(value)
      end
    end
  end
end
