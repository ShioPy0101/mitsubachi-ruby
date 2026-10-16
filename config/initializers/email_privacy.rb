# Action Mailer の標準debugログはMIME本文・宛先・認証URLを含む。
# 配信結果は本文を保存しない構造化イベントで追跡し、標準mailログは出力しない。
Rails.application.config.action_mailer.logger = ActiveSupport::Logger.new(File::NULL)
