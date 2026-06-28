class ApplicationMailer < ActionMailer::Base
  default from: mail_from

  private

  def self.mail_from
    Rails.env.production? ?
      ENV.fetch("MAIL_FROM") :
      ENV.fetch("MAIL_FROM", "test@example.com")
  end
end