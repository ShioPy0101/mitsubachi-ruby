# メールidentityの不可逆化

`users.email_digest` は専用鍵による HMAC-SHA256 の64文字hex。`secret_key_base` は使用しない。
入力に既存と同じ `strip.downcase` を適用する。Deviseの設定は `case_insensitive_keys = [:email]`、`strip_whitespace_keys = [:email]`。
プロバイダ固有のdot/plus除去、Unicode正規化は行わない。
ユーザー・認証リンク・招待先・メール変更先をdigestで照合し、ユーザーと有効な変更先にはDB UNIQUEを設ける。

## 鍵の設定

運用担当者が32bytes以上のランダム専用鍵を作成し、Rails credentialsのトップレベル `email_identity_hmac_key`、またはsecret manager経由の `EMAIL_IDENTITY_HMAC_KEY` に設定する。
環境変数があればそちらを優先する。鍵の生成例は `openssl rand -hex 32`。生成結果をログ、チケット、リポジトリに保存しない。
この変更では `.env`、credentials、本番DB設定ファイルを編集していない。
テストはtest_helperで公開のテスト専用鍵を設定する。本番の代替鍵やsecret_key_baseへのfallbackはない。

初回backfillでDBに鍵のfingerprintを固定する。メール入力・検索・認証・移行でfingerprintを照合し、未設定・短い鍵・鍵変更を検知したら停止する。
鍵はバックアップと同じ重要度で管理し、全web/worker/taskで同じ値を使用する。fingerprintだけ書き換えてはいけない。
消去後のdigestから新しい鍵のdigestは計算できない。通常のsecret rotationと一緒に変更しない。
旧平文が残る検証段階なら、書き込み停止と保護されたDB復元を含む専用移行を設計してから変更する。
平文消去後の鍵喪失・漏洩には、独立した本人確認と再登録の運用が必要であり、自動rotationは実装しない。

## 段階的なcutover（maintenance window）

自動migrationはカラムの追加と旧カラムのnullable化のみ。既存平文の削除は含まない。
アプリは旧カラムをignored_columnsで除外するので、**backfill前に新コードの通常トラフィックを再開しない**。
これは書き込み停止を伴う段階移行であり、旧・新workerの同時稼働を前提とした無停止移行ではない。

1. 復旧可能な保護されたバックアップを取得し、専用鍵を保管する。平文入りのバックアップには保持期限とアクセス制限を設ける。
2. ログイン・登録・管理更新・メール変更など全writerを停止する。既存のメール配信ジョブを旧workerでdrainしてから停止する。
3. 新リリースのコマンド実行環境で `bin/rails db:migrate` を実行する。web/workerは停止したままとする。
4. `bin/rails mitsubachi:email_identities:backfill` を実行する。再実行可能。usersだけでなく認証履歴・招待先・変更先も対象とする。
5. `bin/rails mitsubachi:email_identities:verify` を実行する。元アドレスのHMACと全件照合する。欠損・不一致・重複があれば停止する。自動的なユーザー統合・アドレス修正は行わない。
6. ここでバックフィル結果・件数と鍵の保管を運用担当者が確認する。**この時点までは元アドレスを保持する**。digestと元メールが一致する間は再検証できる。
7. `bin/rails mitsubachi:email_identities:scrub_logs` で既存の監査ログ・システムイベント・アクセスログ内のメールを伏せる。行・ID・日時は保持する。
8. `bin/rails mitsubachi:email_identities:finalize` を実行する。全identityテーブルを排他ロックし再照合してから、同一transactionで旧カラムと旧indexを削除し、必須digestをNOT NULLにする。失敗時は全削除をrollbackする。成功後もverify/finalizeを再実行できる。
9. 新web/worker/scheduler、更新したNginx設定、対応済みフロントエンドを起動する。`EmailIdentities::CleanupJob` が毎分実行されることを確認する。
10. 登録・ログイン・メール変更・招待参加の運用確認をする。既存の未使用Magic Linkはdigestへの移行により継続できる。session saltの変更により既存ログインsessionは失効し、再ログインが必要。

finalizeは不可逆であり、旧アプリへの単純rollbackはできない。失敗調査中は旧カラムを削除せず、writerを再開しない。
旧方式の保留メール変更は旧アドレス承認情報を持たないので、新方式で再申請する必要がある。期限後cleanupで予約を解放する。
リポジトリの `db/schema.rb` は追加段階を表す。schema loadで新環境を作った場合も、専用鍵を設定し空DBにbackfill/verify/finalizeを実行する。通常のdb:migrateだけでは平文消去まで完了しない。

## フロントエンド連携とメール変更

本リポジトリはAPI専用で、ログイン画面は別フロントエンドが提供する。以下の連携がデプロイ条件。

1. メール変更の入口では一度ログイン画面を表示し、現在のメールを入力させる。既存sessionだけでは変更申請を許可しない。
2. `POST /api/v1/auth/login` に `{email, intent: "email_change"}` を送る。通常ログインと同じMagic Linkで所有を確認する。
3. リンクの `/auth/verify?...&intent=email_change` を開き、`POST /api/v1/auth/login/verify`（または共通verify）で認証する。応答の `email_change_reauthenticated=true` ならメール変更画面へ戻す。sessionが再生成されるためCSRF tokenも再取得する。
4. 5分以内に新メールを `POST /api/v1/me/email_change` に送る。再認証は一度の申請にだけ利用できる。未再認証・期限切れは401 `reauthentication_required`、detailsに `login_path=/login` と `intent=email_change` が入るのでログイン画面へ戻す。
5. 旧メールに承認URL `/settings/email-change/approve?token=...` が届く。画面で明示的に承認して `POST /api/v1/me/email_change/approve` にtokenを送る。GETやメールscannerのアクセスだけでは変更しない。この段階ではユーザーidentityは変わらない。
6. 新メールに確認URL `/settings/email-change/verify?token=...` が届く。確認画面から `POST /api/v1/me/email_change/verify` に新tokenを送る。この確認が成功した場合だけidentityを更新し、旧メールへ完了通知を送る。
7. 旧tokenは新tokenへ置き換え、用途の取り違え・再利用・取消後の使用を拒否する。申請後にidentityが別途変更された場合も拒否する。旧session/remember cookieと旧メール用Magic Linkは変更後には使用できない。新メールでログインし直す。

メール変更の旧・新宛先は二段階の送信に必要な30分間だけ、用途・期限付きAES-256-GCMの暗号文として保存する。HMAC identityの復元には使わない。
完了・取消・再申請で消去し、期限切れは定期jobで暗号文を消去する。再認証用の旧宛先は最大15分の暗号文で、申請に使用した時点でも消去する。
メール変更メールは既存設計に合わせ同期送信し、送信失敗ではtransactionをrollbackする。SMTP配信自体はDB transactionで取り消せないので、応答不明時に通知が重複する可能性は残る。

APIの `email`、`pending_email`、`owner_email`、招待先メールは常にnull。メールを表示名のfallbackにしない。
`/me` の `email_change_stage` は `awaiting_old_email_approval` / `awaiting_new_email_confirmation` / null。
管理ユーザー検索のqは名前の部分一致または正規化したメールの完全一致。メールの部分一致・メール順sortは廃止し、旧 `sort=email` は既定のcreated_atへfallbackする。
Devise標準ルートは引き続き無効。password validationとsession、Devise共通検索入口は維持する。Recoverableの検索でも入力宛先をそのリクエスト内だけに保持し、保存済みUserから宛先を復元する機能はない。

## 他の永続ストレージ

- Magic LinkのActive Job引数には平文宛先・raw tokenを入れず、期限付き暗号化宛先とレコード参照を渡す。旧バージョンのジョブはcutover前にdrainし、finished/failed job・実行履歴の保持ポリシーに沿って旧引数を消去する。現行Solid Queueのfinished job定期消去も動作確認する。
- Action Mailer標準ログは本文・宛先・tokenを含むため無効。新配信jobは引数ログを無効化し、SMTP例外はクラスだけを残して宛先とcauseを除去する。
- Rails parameter filterはemail/tokenと管理検索qを伏せる。監査snapshotはdigestを使い、例外/任意metadataにもメールの伏字化を適用する。rate limit cacheはメール原文をキーに保存しない。
- Nginx access logからquery string・Referer・User-Agentを除外する。実稼働のCDN/ロードバランサ/APMでもbody、query、mailer instrumentationの宛先を収集しない設定を確認する。Nginxの実行バイナリがない開発環境では `nginx -t` は別途デプロイ前に実行する。
- 旧テキストログ・DB backup/WAL/replica・キューbackup・SMTPサービスの送信履歴・受信者のメールボックスはDBカラム削除で消えない。既存の保持期限とアクセス制限に沿って別途消去する。メールの配送に必要なSMTPサービスへの宛先送信は引き続き発生する。
