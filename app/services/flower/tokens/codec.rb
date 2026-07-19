module Flower
  module Tokens
    module Codec
      module_function

      def generate_token
        SecureRandom.urlsafe_base64(48)
      end

      def digest(value)
        Digest::SHA256.hexdigest(value.to_s)
      end
    end
  end
end
