class ApplicationMailer < ActionMailer::Base
  def self.mail_from
    if Rails.env.production?
      ENV.fetch("MAIL_FROM")
    else
      ENV.fetch("MAIL_FROM", "test@example.com")
    end
  end

  default from: mail_from
  layout "mailer"
end
