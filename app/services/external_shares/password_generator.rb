require "securerandom"

module ExternalShares
  class PasswordGenerator
    ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789".freeze
    DEFAULT_LENGTH = 16

    def self.generate(length: DEFAULT_LENGTH)
      new(length: length).generate
    end

    def initialize(length: DEFAULT_LENGTH)
      @length = length
    end

    def generate
      Array.new(@length) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
    end
  end
end
