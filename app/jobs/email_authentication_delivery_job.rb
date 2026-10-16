# SMTP応答には宛先が含まれ得るため、ジョブ失敗の自動ログには例外クラスだけを渡す。
class EmailAuthenticationDeliveryJob < ActionMailer::MailDeliveryJob
  self.log_arguments = false
  DeliveryError = Class.new(StandardError)

  def perform(...)
    super
  rescue StandardError => error
    raise DeliveryError, "Email delivery failed (#{error.class})", cause: nil
  end
end
