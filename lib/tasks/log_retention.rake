namespace :logs do
  desc "設定された保持期間を過ぎたログをバッチ削除する"
  task retain: :environment do
    puts Logs::Retention.new.call.inspect
  end
end
