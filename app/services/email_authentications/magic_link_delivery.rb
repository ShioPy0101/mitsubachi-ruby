module EmailAuthentications
  class MagicLinkDelivery
    def self.call(email:, organization:, authentication:)
      new(email:, organization:, authentication:).call
    end

    def initialize(email:, organization:, authentication:)
      @email = email
      @organization = organization
      @authentication = authentication
    end

    def call
      case authentication.purpose
      when "login"
        EmailAuthenticationMailer.with(
          email: email,
          authentication: authentication
        ).login_link.deliver_later
      when "registration"
        EmailAuthenticationMailer.with(
          email: email,
          organization: organization,
          authentication: authentication
        ).registration_link.deliver_later
      else
        raise ArgumentError, "Unknown email authentication purpose: #{authentication.purpose.inspect}"
      end
    end

    private

    attr_reader :email, :organization, :authentication
  end
end
