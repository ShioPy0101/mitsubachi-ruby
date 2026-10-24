# 鍵そのものは保存せず、誤った鍵による検索不能・別identity作成をDB単位で防止する。
class EmailIdentityKey < ApplicationRecord
  def self.verify!
    expected = EmailIdentities::Digest.fingerprint
    row = find_by(id: 1)
    unless row && ActiveSupport::SecurityUtils.secure_compare(row.fingerprint, expected)
      raise EmailIdentities::Digest::ConfigurationError, "Email identity key mismatch or backfill not initialized"
    end
  end

  def self.bind!
    create_or_find_by!(id: 1) { |row| row.fingerprint = EmailIdentities::Digest.fingerprint }
    verify!
  end
end
