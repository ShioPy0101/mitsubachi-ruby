require "digest"

module Security
  class RateLimiter
    Result = Data.define(:allowed?, :retry_after)

    def initialize(namespace:, key:, limit:, period:)
      @namespace = namespace
      @key = key
      @limit = limit
      @period = period
    end

    def call
      count = Rails.cache.increment(cache_key, 1, expires_in: @period)
      count = initialize_counter if count.nil?

      Result.new(count <= @limit, @period.to_i)
    end

    private

    def initialize_counter
      Rails.cache.write(cache_key, 1, expires_in: @period)
      1
    end

    def cache_key
      digest = Digest::SHA256.hexdigest(@key.to_s)
      "rate-limit:#{@namespace}:#{digest}"
    end
  end
end
