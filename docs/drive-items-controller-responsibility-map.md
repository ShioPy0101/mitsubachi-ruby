# DriveItemsController 責務マップ

## 目的

`Api::V1::DriveItemsController` が現在担っている責務と依存関係を可視化し、仕様確認、障害調査、テスト設計、段階的な責務分離の判断材料にする。

この文書は現状を説明するものであり、記載した分割候補を一度に実施することは前提としない。特に upload、move、restore は transaction、row lock、ファイルシステム操作、監査記録の順序に意味があるため、分離時も既存の順序と回帰テストを維持する。

## Controller の境界

```text
HTTP request
  │
  ├─ ApplicationController
  │    ├─ Cookie session / CSRF
  │    ├─ suspended user の拒否
  │    ├─ current organization の解決
  │    └─ OperationLog の共通記録
  │
  ▼
DriveItemsController
  ├─ request parameter と header の解釈
  ├─ organization 境界内の対象取得
  ├─ use case の進行制御
  ├─ domain conflict の API error への変換
  ├─ response JSON / download response の生成
  └─ operation / access / system event の記録指示
       │
       ├─ DriveItem / UploadAttempt / Organization
       ├─ DriveItems::* services
       ├─ UploadAttempts::RecoveryService
       ├─ DriveItemAccessLogs::*
       └─ SystemEvents::Recorder
```

すべてのactionは `authenticate_user!` を通る。Organization指定付きrouteでは `set_current_organization` がmembershipを検証し、通常routeでは `current_user.organization` が既定のscopeになる。DriveItemの検索は原則として `DriveItems::Query` または `current_organization.drive_items` を起点にする。

## Public action の責務

| action | 入力・対象 | 主な責務 | 主な委譲先 | 副作用・記録 |
| --- | --- | --- | --- | --- |
| `index` | `parent_id` | active itemの一覧取得 | `DriveItems::Query#list` | なし |
| `search` | `q`, `scope`, pagination | organization内検索、ページング | `DriveItems::Query#active` | なし |
| `create` | item属性、upload、upload policy | directory作成またはfile upload全工程の進行 | `StoredFileInspector`, `LockPlan`, `UploadAttempts::RecoveryService`, `UploadAttempt` | DB更新、実ファイルstaging/publish/cleanup、OperationLog、upload metric log |
| `show` | active item ID | 詳細とbreadcrumbの返却 | `DriveItems::Query#find_active` | なし |
| `update` | name, parent ID | 名前変更と同一organization内の親変更 | Controller内で検証・保存 | OperationLog |
| `move` | parent ID, destination organization ID | 単一treeの移動、organization変更 | `TreeCollector` | root/descendant更新、OperationLog |
| `destroy` | active item ID | 単一treeの論理削除 | `TrashService` | OperationLog |
| `trash` | optional parent ID | ゴミ箱rootまたは子要素の一覧 | `TrashRootsQuery`, `TrashChildrenQuery` | なし |
| `bulk_move` | item IDs、移動先 | 複数treeの移動 | `TreeCollector` | 複数DB更新、item単位とbulkのOperationLog |
| `bulk_delete` | item IDs | 複数treeの論理削除 | `TrashService` | bulk OperationLog |
| `restore` | deleted item、resolution | 単一treeの復元または競合解決 | `RestoreService`, `RestoreConflictService`, `RestoreResolutionService` | DB更新、OperationLog |
| `restore_preview` | deleted item、resolution | 単一treeの復元結果・競合の事前計算 | `RestorePreviewService` | なし |
| `bulk_restore` | item IDs、resolution | 複数treeの復元または競合解決 | restore系services | DB更新、bulk OperationLog |
| `bulk_restore_preview` | item IDs、resolution | 複数treeの復元結果・競合の事前計算 | `RestorePreviewService` | なし |
| `purge` | deleted item ID | 単一treeの論理purgeと実ファイル削除 | `PurgeService` | DB更新、storage削除、OperationLog |
| `bulk_purge` | item IDs | 複数treeのpurge | `BulkPurgeService` | DB更新、storage削除、bulk OperationLog |
| `preview` | deliverable file ID | inline配信許可 | `DeliveryService` | DriveItemAccessLog、`X-Accel-Redirect` |
| `stream` | deliverable file ID | inline配信許可 | `DeliveryService` | 重複抑止付きDriveItemAccessLog、`X-Accel-Redirect` |
| `download` | deliverable item ID | file配信またはdirectory ZIP生成 | `DeliveryService`, `BulkDownloadService` | DriveItemAccessLog、OperationLog、storage失敗時SystemEvent |
| `bulk_download` | item IDs | 複数itemのZIP生成と配信 | `BulkDownloadService`, `BulkRecorder` | item単位DriveItemAccessLog、失敗時SystemEvent |

## 内部責務のまとまり

### 1. 対象取得とテナント境界

対象メソッド:

- `set_active_drive_item`
- `set_deleted_drive_item`
- `set_deliverable_drive_item`
- `can_access_organization?`
- `drive_item_query`
- `active_drive_items_for_bulk`
- `deleted_drive_items_for_bulk`
- `move_destination_organization`

active、deleted、deliverableをactionごとに使い分ける。別OrganizationのIDが指定された場合は存在推測を避けるため、原則としてnot foundへ変換する。移動だけはユーザーが所属する別Organizationを移動先にできるため、単一Organization scopeより広いmembership検証を行う。

### 2. 入力正規化とAPI validation

対象メソッド:

- `normalized_parent_id`
- `normalized_upload_id`
- `replace_trashed_drive_item_id`
- `get_extension_from_filename`
- `valid_item_type?`
- `file_item_without_upload?`
- `directory_item_with_upload?`
- `validate_parent_id`
- `valid_upload_session_id`
- `upload_too_large?`

空文字と`nil`の統一、item typeとuploadの組み合わせ、親directory、upload ID、サイズ上限をHTTP入力境界で検査する。Model validationだけに任せず、API固有のerror codeとmessageを返す責務を持つ。

### 3. Upload orchestration

対象メソッド:

- `create`
- `upload_attempt_for`
- `retry_upload_attempt!`
- `transition_if_allowed`
- `transition_upload_attempt_or_processing`
- `render_completed_upload_attempt`
- `render_processing_upload_attempt`
- `save_uploaded_file`
- `compensate_unpublished_drive_item!`
- `build_storage_key`
- `cleanup_uploaded_file!`

file uploadは次の順序で進む。

```text
request validation
  → UploadAttempt lock / idempotency判定
  → staging fileへchunk copy・hash・size・content type計算
  → content / name / parent conflict検査
  → DB transactionでDriveItem確定
  → transaction commit後にfinal pathへpublish
  → OperationLog記録
  → response
```

DB transaction内へ実ファイルpublishを含めない。publish失敗時は作成済みDriveItemをpurged相当へ補償し、UploadAttemptを失敗状態へ遷移させる。再試行時は `UploadAttempts::RecoveryService` が残存artifactを整理する。

### 4. Upload conflict と競合解決

対象メソッド:

- `upload_resolution_policy`
- `active_content_upload_anyway?`
- `active_content_duplicate_item`
- `trash_content_duplicate_item`
- `duplicate_active_item?`
- `replace_target_for_upload`
- `replace_trashed_upload!`
- `validate_replace_target_state!`
- `commit_new_upload_after_replace_target_gone!`
- `render_upload_unique_conflict`
- `record_upload_warning!`

事前検査だけでは並行requestとのraceを防げないため、commit直前にparentと関連DriveItemを規定順でlockし、同じ検査を繰り返す。最後はDB unique constraintも競合判定へ変換する。

ゴミ箱内の同一内容fileを置換する場合は、新DriveItemの作成と旧DriveItemのpurgeを同じDB transactionで行う。旧実ファイルは新しいDB状態が確定してから削除する。lock取得までに置換対象が別requestでpurgeされた場合は、条件を再検査したうえで通常の新規uploadへ切り替える。

### 5. Move orchestration

対象メソッド:

- `assign_parent_for_move!`
- `invalid_move_target?`
- `descendant_id?`
- `move_drive_item_tree!`
- `update_drive_items!`

自分自身、同じ場所、自身のdescendantへの移動を拒否する。Organization間移動ではrootだけでなく全descendantの `organization_id` を同じtransactionで更新する。`TreeCollector` が移動前treeに別Organizationのitemが混入していないことを保証する。

### 6. Trash、restore、purge

対象メソッド:

- `restore_preview_json`
- `restore_with_resolutions!`
- `restore_drive_item!`
- `restore_target_for`
- `effective_deleted_at`
- `deleted_ancestor`
- `restore_resolution_items`

trashとpurgeの変更処理はServiceへ委譲済みである。restoreは、復元先決定、競合検査、preview、ユーザーが選んだresolution適用という複数段階をControllerが接続している。

### 7. File delivery とZIP lifecycle

対象メソッド・class:

- `deliver_drive_item`
- `download_folder`
- `record_bulk_download_access!`
- `send_zip_file`
- `archive_metadata`
- `record_archive_delivery_failure!`
- `TemporaryFileBody`

通常fileは `DeliveryService` が検証とaccess log記録を行い、Railsは `X-Accel-Redirect` headerだけを返す。directoryおよびbulk downloadは一時ZIPを生成するため、response bodyの `close` で必ずcleanupする。response構築中の例外でも明示的にcleanupし、内部障害はSystemEventへ記録する。

### 8. Response projection とerror変換

対象メソッド:

- `drive_item_json`
- `breadcrumbs_for`
- `duplicate_content_file_json`
- `trash_duplicate_json`
- `restore_target_json`
- `original_parent_json`
- `uploaded_by_json`
- `drive_item_path`
- `duplicate_name_details`
- `render_*`
- `error_code_for_status`

DriveItemの通常表現だけでなく、検索、breadcrumb、重複内容、ゴミ箱重複、復元候補に必要なprojectionをController内で組み立てる。Serviceのstatusや例外を公開APIのerror code、HTTP status、detailsへ変換する。

### 9. 監査とobservability

対象メソッド:

- `record_drive_item_event!`
- `record_bulk_drive_item_event!`
- `record_bulk_download_access!`
- `record_archive_delivery_failure!`
- `observe_upload_request`
- `timed_upload_phase`

記録先は事実の種類で分かれる。

| 事実 | 記録先 |
| --- | --- |
| create、move、delete、restore、purgeなどユーザー操作 | `OperationLog` |
| preview、stream、download、ZIP内fileへのアクセス | `DriveItemAccessLog` |
| ZIP生成・配信などstorage内部障害 | `SystemEvent` |
| uploadのstorage時間、DB時間、総時間 | structured application log |

## Transaction、lock、ファイル操作の境界

| use case | DB transaction | row lock | transaction外のファイル操作 |
| --- | --- | --- | --- |
| 新規upload | DriveItem作成、UploadAttempt更新 | UploadAttempt、parent | staging copy、publish、temporary cleanup |
| ゴミ箱file置換 | 新DriveItem作成、旧DriveItem purge、UploadAttempt更新 | UploadAttempt、parent、置換対象 | publish、旧storage cleanup |
| 単一・複数move | root保存、descendantのOrganization更新 | 明示的なtree lockはなし | なし |
| trash | `TrashService`内 | `LockPlan`によるtree lock | なし |
| restore | restore系Service内 | restore系Serviceで対象をlock | なし |
| purge | purge系Service内 | purge系Serviceで対象をlock | commit後にstorage削除 |
| ZIP download | なし | なし | 一時ZIP作成、response close時cleanup |

upload系では `UploadAttempt` を先にlockし、その後のDriveItemはID昇順でlockする。DB commitとファイルpublishの間では一時的にDB recordだけが存在し得るため、補償処理とrecoveryを削除してはならない。

## 依存Serviceマップ

```text
DriveItemsController
  ├─ query
  │    ├─ DriveItems::Query
  │    ├─ DriveItems::TrashRootsQuery
  │    └─ DriveItems::TrashChildrenQuery
  ├─ upload
  │    ├─ DriveItems::StoredFileInspector
  │    ├─ DriveItems::LockPlan
  │    └─ UploadAttempts::RecoveryService
  ├─ tree mutation
  │    ├─ DriveItems::TreeCollector
  │    ├─ DriveItems::TrashService
  │    ├─ DriveItems::PurgeService
  │    └─ DriveItems::BulkPurgeService
  ├─ restore
  │    ├─ DriveItems::RestoreService
  │    ├─ DriveItems::RestoreConflictService
  │    ├─ DriveItems::RestorePreviewService
  │    └─ DriveItems::RestoreResolutionService
  ├─ delivery
  │    ├─ DriveItems::DeliveryService
  │    └─ DriveItems::BulkDownloadService
  └─ audit / observability
       ├─ DriveItemAccessLogs::Recorder
       ├─ DriveItemAccessLogs::BulkRecorder
       ├─ OperationLogs::Recorder（ApplicationController経由）
       └─ SystemEvents::Recorder
```

## Controllerに残す責務と分割候補

将来分割する場合も、Controllerには次を残す。

- HTTP parameterとheaderの受け取り
- authentication / organization選択の入口
- use case objectの呼び出し
- resultからHTTP responseへの変換
- response body lifecycleの接続

優先度順の分割候補は次のとおり。

1. **Upload use case**: `create` のfile upload、directory作成、ゴミ箱置換を個別のServiceへ移し、状態遷移と補償を集約する。
2. **Move use case**: 単一・bulkで共有すべきtree検証とOrganization更新をServiceへ集約する。
3. **Response projection**: 通常表示、重複表示、restore preview表示をSerializer相当のobjectへ分ける。
4. **Archive delivery**: ZIP生成、access log、response body cleanup、失敗記録の順序を専用Service/resultへ集約する。

分割単位は「private methodの移動」ではなく、transaction、lock、監査、補償を含めて完結するuse case単位とする。Service化後もController integration testを残し、外部から観測できるstatus、error code、header、DB状態、実ファイル状態、ログを検証する。

## 変更時の確認ポイント

- すべての検索が選択中Organizationまたはmembershipで許可された移動先にscopeされているか。
- directory移動でdescendantの `organization_id` も更新されるか。
- active name重複を事前検査とDB constraintの両方で扱っているか。
- uploadのlock順序が `UploadAttempt`、DriveItem ID昇順になっているか。
- DB commit前にfinal storageへpublishしていないか。
- publish失敗時にDriveItem、UploadAttempt、一時fileを回復可能な状態にしているか。
- preview、stream、downloadの許可前にaccess logを記録しているか。
- ZIP responseの正常終了と例外の両方で一時fileが削除されるか。
- OperationLog、DriveItemAccessLog、SystemEventへ同じ事実を重複記録していないか。
- 他OrganizationのID指定からresourceの存在を推測できないresponseになっているか。

## 関連資料

- `docs/architecture.md`
- `docs/log-management.md`
- `docs/api.yml`
- `app/models/upload_state_machine.rb`
- `app/services/drive_items/lock_plan.rb`
- `test/controllers/drive_items_controller_test.rb`
- `test/integration/drive_item_delivery_test.rb`
