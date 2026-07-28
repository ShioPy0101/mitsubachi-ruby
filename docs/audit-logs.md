# ログ管理

「監査ログ」という曖昧な主要画面名は廃止し、フロントエンドは「操作履歴」「ファイルアクセス履歴」「システムイベント」を別画面として実装する。

## 記録先の判断

| 事実 | 保存先 | 主体・目的 |
| --- | --- | --- |
| 認証、設定変更、作成、更新、移動、削除、復元、権限変更、拒否 | `operation_logs` | 人間が誰に何をしたか |
| preview、stream、download、bulk/folder download、外部共有・Flower配信 | `drive_item_access_logs` | 実ファイルへ誰がアクセスしたか |
| ジョブ、メール、ストレージ、保守処理の重要な成功・異常 | `system_events` | 内部で何が起きたか |

ユーザー操作を契機に内部ジョブが失敗した場合は、操作と内部失敗をそれぞれ保存する。同じ事実は複製しない。DB接続障害など同じDBへ安全に保存できない事象は `Rails.logger` / journald のみに残す。

## OperationLog

`actor_kind` は `user`、`external_share`、`anonymous`。anonymousの関連IDはNULLとする。`result` は `success`、`failure`、`denied` でありseverityを持たない。イベント名は `<domain>.<past-tense event>`（例 `drive_item.deleted`、`organization.settings_updated`）とする。ファイル内容アクセスは含めない。

旧 `audit_events` はID・日時を維持して `operation_logs` へrenameし、`action` は `operation_type`、`outcome` は `result` へrenameする。旧アクセスイベントは冪等な `bin/rails logs:backfill_file_access` でアクセスログへ移し、確認後に操作履歴から除く。未認証メールは平文ではなく、正規化値のHMACである `email_identifier` のみ保存する。

## DriveItemAccessLog

ファイルアクセス専用。ファイル名、hash、size、content type、client typeは `metadata` のスナップショットとして残し、生の共有token・storage keyは保存しない。外部共有削除時はFKをNULL化して履歴を維持する。streamは同一organization・actor・DriveItemについて5分間重複抑止する。一括・フォルダ配信はファイル単位で保存し、共通のrequest_idまたはbatch_idで束ねる。

## SystemEvent

severityは `info`、`warning`、`error`、`critical`、sourceは `application`、`worker`、`mailer`、`storage`、`database`、`maintenance`。全Railsログの複製ではなく、管理画面で追跡する価値がある構造化イベントだけを保存する。Recorder失敗は本処理を壊さずloggerへ出し、再帰記録しない。

metadataは大文字小文字・nestを問わずauthorization、cookie、session、各種token、password、secret、api key、SMTP credential、database URL、magic link、CSRF tokenをマスクする。絶対パスと例外情報も最小化する。

## 閲覧権限とAPI

Organization管理者は管理対象Organizationの操作履歴、アクセス履歴、秘匿詳細を除いたSystemEventを閲覧できる。system adminは全OrganizationとSystemEvent詳細を閲覧できる。一般ユーザーは管理APIを利用できない。Organization未確定の匿名認証操作はsystem adminだけが閲覧できる。

- `GET /api/v1/admin/operation_logs`
- `GET /api/v1/organizations/:organization_id/admin/operation_logs`
- `GET /api/v1/admin/drive_item_access_logs`
- `GET /api/v1/organizations/:organization_id/admin/drive_item_access_logs`
- `GET /api/v1/organizations/:organization_id/admin/system_events`
- `GET /api/v1/system_admin/system_events`

旧 `audit_events`、`audit_logs`、`file_access_logs` APIはdeprecated互換APIで、新テーブルを参照し旧テーブルへ書き込まない。

## 保持期間と個人情報

未設定時は自動削除しない。`OPERATION_LOG_RETENTION_DAYS`、`DRIVE_ITEM_ACCESS_LOG_RETENTION_DAYS`、`SYSTEM_EVENT_{INFO,WARNING,ERROR,CRITICAL}_RETENTION_DAYS` を個別指定し、`bin/rails logs:retain` が小分けに削除する。完了件数は削除後に `maintenance.log_retention_completed` として1件追加される。

IPアドレス、User-Agent、メール識別子、ファイル名は、不正操作・情報流出・配信経路の調査のためだけに保持し、上記の権限と保持期間を適用する。新規イベントでは「人間の意思」「実ファイル配信」「内部事象」の順に判定し、最も具体的な一つの保存先を選ぶ。
