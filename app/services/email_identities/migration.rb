module EmailIdentities
  # アプリのvalidation/callbackを通さず旧カラムを扱い、将来のモデル変更から移行を分離する。
  # 平文をログや例外に含めない。finalize は書き込み停止中に実行する運用コマンド。
  class Migration
    TABLES = {
      "users" => [ "email", "email_digest", true ],
      "email_authentications" => [ "email", "email_digest", true ],
      "organization_invites" => [ "email", "email_digest", false ],
      "user_email_changes" => [ "new_email", "new_email_digest", true ]
    }.freeze

    def backfill!
      EmailIdentityKey.bind!
      TABLES.each do |table, (source, target, required)|
        model(table).find_each do |row|
          row.with_lock do
            next if row[source].blank? && !required
            next if row[source].nil? && row[target].present?

            expected = Digest.call(row[source])
            if row[target].present? && row[target] != expected
              raise "Email digest mismatch: #{table} id=#{row.id}"
            end
            row.update_columns(target => expected) if row[target].nil?
          end
        end
      end
      verify!
    end

    def verify!
      EmailIdentityKey.verify!
      TABLES.each do |table, (source, target, required)|
        model(table).find_each do |row|
          if (required && row[target].blank?) || (row[source].present? && row[target] != Digest.call(row[source]))
            raise "Email digest verification failed: #{table} id=#{row.id}"
          end
        end
      end
      true
    end

    # 全テーブルを排他ロックし、検証と削除の間に旧workerが書き込む競合を防ぐ。
    # 元データは全件検証に成功したtransactionでのみ消去し、以後DB制約でも平文保存を拒否する。
    def finalize!
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("LOCK TABLE #{TABLES.keys.join(', ')} IN ACCESS EXCLUSIVE MODE")
        verify!
        TABLES.each do |table, (source, target, required)|
          model(table).where.not(source => nil).update_all(source => nil)
          connection.change_column_null(table, target, false) if required
          name = "#{table}_legacy_email_cleared"
          unless connection.check_constraint_exists?(table, name: name)
            connection.add_check_constraint(table, "#{source} IS NULL", name: name)
          end
        end
      end
    end

    private

    def model(table)
      Class.new(ApplicationRecord) do
        self.table_name = table
        self.inheritance_column = :_disabled
      end
    end
  end
end
