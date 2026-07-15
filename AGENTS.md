# AGENTS

- このリポジトリのテスト基盤は Minitest (`test/`, `test/test_helper.rb`)。
- 通常作業では `bin/ai-check`、最終確認では `bin/check` を使う。
- `.env`、credentials、本番 DB 設定には触れない。
- AI 用の自動化に `db:drop`、`db:reset`、`db:purge`、`db:seed:replant` を入れない。

## Git / Commit rules

- `main` またはデフォルトブランチ上で、機能実装を直接コミットしてはならない。
- 機能追加、バグ修正、リファクタリングを開始する前に、必ず作業ブランチを作成して切り替える。
- 未コミット変更がすでに存在する場合も、その変更を保持したまま作業ブランチを作成する。
- ブランチ名には `feat/`、`fix/`、`refactor/`、`test/`、`chore/` のいずれかを使用する。
- 実装完了後は、すべての変更を論理的に独立した単位でコミットする。
- 変更を未コミットのまま作業完了として報告してはならない。
- コミット後、作業ブランチを必ず `origin` へ push する。
- commitせずに作業完了として報告してはならない。
- 最終報告には、ブランチ名、コミット一覧、push先、`git status --short` の結果を含める。
- ユーザーから明示的に依頼されていない限り、既存コミットの amend、rebase、force push は行わない。

## Test rules

- 振る舞いを変更・追加する場合は、対応するテストも追加または更新する。
- バグ修正では、原則として修正前に失敗し、修正後に成功する回帰テストを追加する。
- Controllerの振る舞いは request / integration test で確認する。
- Modelのバリデーション、関連、ドメインロジックは model test で確認する。
- Service objectを追加した場合は、可能な限り単体テストを追加する。
- 認証、認可、マルチテナント境界、ファイル配信などの重要経路は正常系だけでなく異常系も確認する。
- 正常系、権限不足、対象不存在、不正入力を必要に応じてテストする。
- 外部APIや外部ストレージはテストで実通信せず、fake、stub、mockを使用する。
- テストは実装詳細ではなく、外部から観測できる振る舞いを検証する。
- 変更箇所に近いテストを先に実行し、最後に必要な範囲の全体テストを実行する。
- コミット前に、そのコミットに関連するテストを実行する。
- タスク完了前に、変更ファイルのLintと関連テストを実行する。
- テストを追加できない場合は、その理由と未検証のリスクを報告する。

## Design rules

- Rails標準のMVCを基本とし、Controller、Model、Serviceの責務を分離する。
- Controllerは、入力の受け取り、認証・認可、Serviceの呼び出し、レスポンス生成を担当する。
- Modelは、バリデーション、関連、スコープ、データに密接なドメインロジックを担当する。
- 複数モデルをまたぐ処理、外部サービスとの連携、トランザクションを伴う処理はService Objectへの分離を検討する。
- 外部ストレージや配信方式など、実装を差し替える可能性がある処理にはStrategy Patternを検討する。
- 条件に応じてStrategyを選択する必要がある場合のみFactoryを用いる。
- 認可条件が複雑になる場合はPolicy Objectへの分離を検討する。
- デザインパターンを使うこと自体を目的にせず、責務分離、変更容易性、テスト容易性を改善する場合にのみ採用する。
- 単純な処理に対して不要なService、Factory、Repositoryなどを追加しない。
- 新しい設計パターンを導入した場合は、採用理由、対象責務、代替案を実装結果に記載する。

## File delivery rules

- Railsは、認証、organization単位の認可、監査ログ、配信レスポンスの生成を担当する。
- 実ファイルの転送はNginxの `X-Accel-Redirect` に委譲し、Railsから大容量ファイルを直接配信しない。
- `X-Accel-Redirect` の内部URIは、ユーザー入力から直接組み立てない。
- ファイルの取得は、原則として `current_user.organization.drive_items` を起点に行う。
- `preview`、`download`、`stream` では、認可成功後かつ配信許可前に監査ログを記録する。
- 監査ログ処理はControllerへ重複して記述せず、Service Objectへ集約する。
- 動画のRangeリクエストによって同一の監査ログが大量生成されないようにする。
- `preview` と `stream` は `Content-Disposition: inline`、`download` は `attachment` とする。
- 不正な `storage_key`、削除済みファイル、実ファイル欠損時は配信を拒否する。
