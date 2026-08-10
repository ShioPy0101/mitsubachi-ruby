# AGENTS

## Project rules

- このリポジトリのテスト基盤は Minitest (`test/`, `test/test_helper.rb`)。
- 通常作業では `bin/ai-check`、最終確認では `bin/check` を使用する。
- `.env`、credentials、本番 DB 設定には触れない。
- AI 用の自動化に `db:drop`、`db:reset`、`db:purge`、`db:seed:replant` を含めない。
- 作業中に Ruby、Rails、Rails 周辺ツールに起因する難しさ、問題、または言語・フレームワークとして改善されるとよい点に気づいた場合は、`docs/ruby-rails-improvement-notes.md` に追記し、その変更も同じ作業ブランチでコミットする。
- 上記の記録は愚痴ではなく、再発防止や設計判断に利用できる観察として記載する。
- 改善記録には、発生日、状況、困った点、望ましい改善、今回の回避策を簡潔に残す。

## Git / GitHub rules

このリポジトリで作業するエージェントは、実装だけでなく、ブランチ作成、コミット、push、Pull Request 作成までを作業範囲とする。

### 作業開始

- 作業開始時に、現在のブランチ、`git status`、既存の未コミット変更を必ず確認する。
- `main`、`master`、その他のデフォルトブランチ上で機能実装を直接コミットしてはならない。
- 機能追加、バグ修正、リファクタリング、テスト追加等を開始する前に、必ず専用の作業ブランチを作成して切り替える。
- 未コミット変更が存在する場合も、それを保持したまま作業ブランチを作成する。
- ユーザーが作成した既存変更を、明示的な依頼なしに削除、上書き、revert、reset、stash してはならない。
- ブランチ名には原則として以下のいずれかを使用する。
  - `feat/`
  - `fix/`
  - `refactor/`
  - `test/`
  - `chore/`

- ブランチ名から変更内容を判断できるようにする。
  - 例: `feat/add-upload-audit`
  - 例: `fix/oauth-token-expiration`
  - 例: `refactor/user-authentication`

### コミット設計

- 調査後、実装着手前に「どの責務をどのコミットにするか」を決める。
- 完成後にまとめてコミット分割することを前提として、大量の差分を未コミットのまま保持しない。
- 実装とコミットを並行して進める。
- 新しい責務の実装へ進む前に、直前の責務に関する変更を可能な限りコミットする。
- 原則として、1つの関数・メソッド、またはそれに対応する小さな責務を1コミットの目安とする。
- 関数本体、関連テスト、必要な設定変更など、単独では成立しない変更は同一コミットに含めてよい。
- migration / model、収集 API、管理 API、定期 job、構造化ログ、API 仕様、テストなど、独立してレビュー可能な責務は別コミットにする。
- 1コミットに複数の独立した目的を混在させない。
- 各コミットは、後続コミットを読まなくても目的と検証方法を理解できる状態にする。
- 各コミットは、可能な範囲で単独でテストが通る状態にする。
- 目安として、1コミットが5ファイルまたは差分300行を超えそうな場合は、不可分である明確な理由がない限りさらに分割する。
- リポジトリ横断の大きな機能であっても、単一の巨大な feature commit にまとめない。
- 3ファイル以上の変更を未コミットで保持した状態が続く場合は、現在の差分を確認し、先にコミット可能な単位を切り出す。

### コミット実行

- コミット前に、対象責務に関連するテストを実行する。
- コミット前に `git diff` および `git diff --cached` を確認する。
- `git add .` を無条件に使用せず、対象ファイルと差分を確認して stage する。
- 一時的なデバッグコード、不要なログ、生成物、秘密情報をコミットしない。
- コミットメッセージから変更内容と目的を判断できるようにする。
- 実装完了後は、すべての変更を論理的に独立した単位でコミットする。
- 変更を未コミットのまま作業完了として報告してはならない。
- ユーザーから明示的に依頼されていない限り、既存コミットの amend、rebase、force push は行わない。

### Push / Pull Request

実装および必要な検証が完了した場合は、原則として以下まで実施する。

1. すべての変更を適切な単位でコミットする。
2. 作業ブランチを `origin` へ push する。
3. GitHub 上で Pull Request を作成する。
4. Pull Request の URL を最終報告に含める。

- push せずに作業完了として報告してはならない。
- ユーザーから「コミットしない」「push しない」「PR を作らない」等の明示的な指示がある場合のみ、その指示を優先する。
- Pull Request は原則 Draft PR として作成する。
- レビュー可能な状態に整理してから PR を作成する。
- 検証に失敗している場合、その事実を隠して完成扱いにしてはならない。失敗内容、原因、未検証範囲を PR 本文および最終報告に記載する。

### Pull Request 本文

Pull Request 本文には最低限、以下を記載する。

- 変更の目的
- 背景・解決する問題
- 実装内容
- 主な設計判断
- 影響範囲
- 実行したテスト・検証
- 未対応事項・既知の制約
- migration の有無
- 設定変更の有無
- 環境変数追加の有無
- デプロイ・運用上の注意事項

単なる変更ファイル一覧ではなく、「なぜこの変更が必要なのか」「どのような設計で解決したのか」「どのように検証したのか」がレビュー担当者に理解できる文章を書く。

### 最終報告

最終報告には最低限、以下を含める。

- 作業ブランチ名
- コミット一覧
- push 先
- Pull Request URL
- 実行したテスト・検証
- `git status --short` の結果
- 未対応事項または既知の問題がある場合はその内容

## Comment rules

このプロジェクトでは、コードを読んだ人が実装意図、制約、責務、データフローを再構築できることを重視する。

コメント量を過度に節約してはならないが、コードを日本語へ逐語的に翻訳するだけのコメントも追加しない。

### 基本方針

- コメントには「何をしているか」より「なぜこの実装なのか」を記載する。
- メソッド名や変数名を言い換えただけのコメントは追加しない。
- 自明な行ごとのコメントは追加しない。
- コメントで複雑さを補う前に、命名改善やメソッド分割によってコード自体を明確にできないか検討する。
- 古くなったコメントや、実装と矛盾するコメントを残さない。
- コード変更時は関連コメントも更新または削除する。
- コメントは原則として日本語で記載する。
- 外部仕様名、HTTP ヘッダー名、クラス名、メソッド名などは原文の英語を使用する。

### コメントを積極的に記載する箇所

以下のような、背景知識がなければ実装意図を誤解しやすい箇所には積極的にコメントを記載する。

- クラス・モジュールの責務
- public method の目的
- 複雑な private method の役割
- 複雑な条件分岐
- business rule
- authentication / authorization の判断
- マルチテナント境界
- transaction boundary
- DB query の意図
- lock や排他制御
- callback を使用する理由
- background job の実行条件
- retry / timeout の理由
- キャッシュ戦略
- セキュリティ上重要な処理
- 外部 API / 外部仕様への対応
- Rails 標準の挙動から意図的に外れる実装
- 一見不要に見えるが必要な処理
- performance optimization のための特殊な実装
- workaround
- 将来変更時に壊れやすい暗黙の前提
- `X-Accel-Redirect`
- マルチテナント認可
- 監査ログの重複抑止
- Range request への対応

悪い例:

```ruby
# ユーザーを取得する
user = User.find(params[:id])

# 名前を更新する
user.update!(name: params[:name])
```

良い例:

```ruby
# Organization を跨いだ User ID 指定による情報漏洩を防ぐため、
# current_organization 経由でのみ対象ユーザーを検索する。
user = current_organization.users.find(params[:id])
```

良い例:

```ruby
# 大容量ファイル転送で Puma worker を占有しないよう、
# Rails は認可までを担当し、実ファイル配信は Nginx に委譲する。
response.headers["X-Accel-Redirect"] = internal_path
```

### YARD

public な Service Object、外部から利用される API、複雑な domain object などでは、必要に応じて YARD 形式のコメントを使用する。

特に以下がコードから直感的に分からない場合は記載を検討する。

- 責務
- 入力
- 戻り値
- 副作用
- 失敗条件
- 例外
- セキュリティ上の前提

すべてのメソッドへ機械的に YARD を追加する必要はない。

例:

```ruby
# Organization 内のファイルを論理削除する。
#
# 物理削除はこの時点では行わず deleted_at のみを設定し、
# 監査ログおよび復元処理から対象を追跡可能な状態を維持する。
#
# @param drive_item [DriveItem] 削除対象
# @param actor [User] 操作を実行したユーザー
# @return [DriveItem] 更新後の DriveItem
# @raise [ActiveRecord::RecordInvalid] 更新に失敗した場合
def delete_drive_item(drive_item:, actor:)
  # ...
end
```

### TODO / FIXME / HACK

`TODO`、`FIXME`、`HACK` を追加する場合は、最低限以下を記載する。

- 具体的に何が問題なのか
- なぜ現在は解決していないのか
- 影響範囲
- 解消条件

悪い例:

```ruby
# TODO: 後で直す
```

良い例:

```ruby
# TODO: Organization ごとの保存容量制限を導入した段階で、
# この判定を StorageQuotaService に集約する。
```

### テストコードのコメント

- テスト名から意図が明確な場合はコメントを追加しない。
- テストデータ、前提条件、操作手順が非直感的な場合のみ理由をコメントする。
- テストコードでも「何をしているか」ではなく「なぜこの条件が必要なのか」を優先する。

## Test rules

- 振る舞いを変更・追加する場合は、対応するテストも追加または更新する。
- バグ修正では、原則として修正前に失敗し、修正後に成功する回帰テストを追加する。
- Controller の振る舞いは request / integration test で確認する。
- Model の validation、association、domain logic は model test で確認する。
- Service Object を追加した場合は、可能な限り単体テストを追加する。
- authentication、authorization、マルチテナント境界、ファイル配信などの重要経路では正常系だけでなく異常系も確認する。
- 正常系、権限不足、対象不存在、不正入力を必要に応じてテストする。
- 外部 API や外部ストレージはテストで実通信せず、fake、stub、mock を使用する。
- テストは実装詳細ではなく、外部から観測できる振る舞いを検証する。
- 変更箇所に近いテストを先に実行する。
- コミット前に、そのコミットに関連するテストを実行する。
- タスク完了前に変更ファイルの Lint と関連テストを実行する。
- 通常作業では `bin/ai-check` を使用する。
- 最終確認では `bin/check` を使用する。
- テストを追加できない場合は、その理由と未検証のリスクを報告する。

## Design rules

- Rails 標準の MVC を基本とし、Controller、Model、Service の責務を分離する。
- Controller は以下を担当する。
  - 入力の受け取り
  - authentication / authorization
  - Service の呼び出し
  - レスポンス生成

- Model は以下を担当する。
  - validation
  - association
  - scope
  - データに密接な domain logic

- 複数モデルをまたぐ処理、外部サービスとの連携、transaction を伴う処理は Service Object への分離を検討する。
- 外部ストレージや配信方式など、実装を差し替える可能性がある処理には Strategy Pattern を検討する。
- 条件に応じて Strategy を選択する必要がある場合のみ Factory を用いる。
- 認可条件が複雑になる場合は Policy Object への分離を検討する。
- デザインパターンを使用すること自体を目的にしない。
- 責務分離、変更容易性、テスト容易性が改善される場合にのみ採用する。
- 単純な処理に不要な Service、Factory、Repository 等を追加しない。
- 新しい設計パターンを導入した場合は、採用理由、対象責務、検討した代替案を実装結果または PR 本文に記載する。

## File delivery rules

- Rails は以下を担当する。
  - authentication
  - organization 単位の authorization
  - 監査ログ
  - 配信レスポンスの生成

- 実ファイル転送は Nginx の `X-Accel-Redirect` に委譲する。
- Rails から大容量ファイルを直接配信しない。
- `X-Accel-Redirect` の内部 URI をユーザー入力から直接組み立てない。
- ファイル取得は原則として `current_user.organization.drive_items` 等、現在の organization に明示的にスコープされた関連を起点に行う。
- `preview`、`download`、`stream` では、authorization 成功後かつ配信許可前に監査ログを記録する。
- 監査ログ処理を Controller へ重複して記述せず、Service Object へ集約する。
- 動画の Range request により同一の監査ログが大量生成されないようにする。
- `preview` と `stream` は `Content-Disposition: inline` とする。
- `download` は `Content-Disposition: attachment` とする。
- 不正な `storage_key`、削除済みファイル、実ファイル欠損時は配信を拒否する。

## Implementation accountability

コードの短さより、将来の保守者が設計意図を再構築できることを優先する。

特に以下の変更では、コードだけを変更して終了してはならない。

- セキュリティ境界の変更
- authentication / authorization の変更
- DB schema の変更
- transaction 範囲の変更
- 非同期処理の導入
- キャッシュの導入
- 外部サービスとの通信追加
- 大容量ファイル処理の変更
- performance optimization
- Rails convention から意図的に外れる設計

これらの変更では、必要に応じて以下の複数箇所から設計意図を確認できる状態にする。

- コードコメント
- テスト
- Pull Request 本文
- 設計ドキュメント

## Definition of Done

以下を満たすまでは、原則として作業完了とみなさない。

- 要件を満たす実装が存在する。
- 必要なテストが追加または更新されている。
- 関連テストが成功している。
- `bin/ai-check` が成功している。
- 最終確認として `bin/check` が成功している。
- 不要なデバッグコードが残っていない。
- 複雑または非直感的な実装に、理由を説明する十分なコメントがある。
- `git diff` および `git diff --cached` を確認済みである。
- すべての変更が適切な単位でコミット済みである。
- 作業ブランチが `origin` へ push 済みである。
- Pull Request が作成済みである。
- Pull Request に目的、設計判断、影響範囲、検証内容が記載されている。
- `git status --short` で意図しない変更が残っていない。

検証に失敗している場合は、その事実を隠して完成扱いにしてはならない。失敗内容、原因、未検証範囲を明示する。
