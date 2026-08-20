# ログ管理設計

ログは、人間の意思による操作を保存する `OperationLog`、実ファイル配信を保存する `DriveItemAccessLog`、内部処理・障害を保存する `SystemEvent` の3系統だけで構成する。同じ事実を複数へ保存しない。

## 分類と命名

- `OperationLog`: 認証、設定変更、メンバー・権限変更、DriveItemの状態変更、外部共有設定、拒否操作。`operation_type` は `対象.過去形`（例 `drive_item.deleted`）、成否は `result` で表す。
- `DriveItemAccessLog`: `preview`、`stream`、`download`、`bulk_download`、`download_folder`。ファイル名・hash・size・content type・client typeは `metadata` にスナップショット保存する。Rangeごとには作成せず、streamは5分間重複抑止する。
- `SystemEvent`: mail、storage、worker、maintenance等の構造化された内部イベント。`event_type` は `source.事象`、重要度は `severity` で表す。ユーザー操作は保存しない。

新規イベントは「誰が何をしたか」が重要ならOperationLog、「どのファイル内容へアクセスしたか」ならDriveItemAccessLog、「内部で何が起きたか」が重要ならSystemEventへ記録する。ユーザー操作を契機に非同期処理が失敗した場合だけ、操作と内部失敗を別々の事実として保存できる。

## actor・PII・秘密情報

actorは `user`、`external_share`、`anonymous`。anonymousは関連IDを持たない。削除済みactor・DriveItemでも履歴はmetadataのスナップショットで表示する。共有token、password、cookie、session、Authorization等は保存しない。

IPアドレス、User-Agent、ファイル名、非可逆なメール識別子は、不正操作・情報流出調査と同一アクセスの追跡に限って保持する。SystemEvent metadataと例外文字列は `SystemEvents::Sanitizer` が大文字小文字・ネストを問わず秘密キー、絶対path、過大文字列を除去する。

## APIと権限

- `/api/v1/admin/operation_logs`、`/api/v1/organizations/:organization_id/admin/operation_logs`
- `/api/v1/admin/drive_item_access_logs`、`/api/v1/organizations/:organization_id/admin/drive_item_access_logs`
- `/api/v1/organizations/:organization_id/admin/system_events`
- `/api/v1/system_admin/system_events`

Organization管理者は管理対象Organizationだけ、system adminは全Organizationを閲覧できる。一般ユーザーは管理APIを利用できない。Organization管理者向けSystemEventはsummaryと識別情報だけを返し、error_message、job/trace情報、内部metadataはsystem adminだけに返す。

## 保持期間

`OPERATION_LOG_RETENTION_DAYS`、`DRIVE_ITEM_ACCESS_LOG_RETENTION_DAYS`、severity別の `SYSTEM_EVENT_*_RETENTION_DAYS` で個別設定する。未設定なら削除しない。削除は小さいbatchで行い、完了件数をSystemEventに残すため、SystemEvent自身の保持後に完了イベントが1件追加される。

## 本番移行とrollback

短時間のmaintenance modeで、DB backup、移行前件数記録、migration、整合性検証、backend/frontend同時配置、health check、新API・3画面・Organization切替・権限境界の確認を行う。drop前の移行はsource、duplicate、migrated、unmigrated、actor/target未解決件数を出力し、unmigratedが1件でもあればmigrationを停止する。

テーブルdrop後はcode rollbackだけでは戻せない。backupから復元するか、`operation_logs` の `legacy_source_id` スナップショットと移行レポートを使って緊急復元する。backend/frontendの直前release IDを作業記録へ残す。
