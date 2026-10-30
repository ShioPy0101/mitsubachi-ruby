# Ruby / Rails 改善メモ

Ruby 言語、Rails、Rails 周辺ツールに起因して実装・保守・検証が難しくなった点を記録する。新しい気づきがあれば、該当作業のコミットに含める。

## 2026-10-30: 推移依存の脆弱性と通常チェックの範囲

- 状況: テナント検査追加のローカル `bin/check` は成功したが、CI の `bin/bundler-audit` が crass と net-ssh の脆弱性を検出した。
- 困った点: crass は HTML sanitizer、net-ssh は Kamal / SSHKit 経由の推移依存であり、通常のテスト・Lint・Brakeman だけでは advisory DB に基づく脆弱性を検出できない。
- 望ましい改善: 検証コマンドごとの検査範囲と advisory DB の更新日時を共通の結果として提示し、ローカルと CI の検査範囲の違いを把握しやすくすること。
- 今回の回避策: `bundle update crass net-ssh --conservative --patch` で対象二つのみを更新し、全体チェックに加えて advisory DB を更新した `bin/bundler-audit` を実行する。

## 2026-10-30: Active Record の動的な Relation と静的テナント検査

- 状況: DriveItem のテナント条件を AST で検査し、既存の組織横断処理も CI の対象にした。
- 困った点: 独自 scope、Relation への後続条件付加、組織条件の消去が同じメソッド呼び出し形式で表現され、構文だけでは組織境界や認可を証明できない。
- 望ましい改善: Active Record の scope に、テナント条件の保持・消去とクエリ実行の性質を静的解析へ伝える共通の宣言があるとよい。
- 今回の回避策: 定数から始まる呼び出し鎖を保守的に検査し、既存の横断式は理由付きの完全一致例外で管理する。データフロー解析の限界を設計文書に明記し、認可テストとコードレビューを併用する。

## 2026-07-25: 単一所属から複数 OrganizationMembership への移行

- 状況: `User` が `organization_id` を持つ単一所属設計から、`OrganizationMembership` 経由の複数所属へ移行した。
- 困った点: Rails の `belongs_to` は標準で presence validation を持つため、互換カラムとして残した `users.organization_id` が `null: false` / required のままだと、membership が正しい状態でも旧カラムが実質的な真実として残り続ける。
- 改善されるとよい点: 移行期間中の legacy association を明示的に非推奨化し、参照箇所を検出しやすくする Rails 標準の仕組みがあるとよい。例えば association に deprecation warning や lint 対象の metadata を付けられると、マルチテナント境界の移行で取りこぼしを減らせる。
- 今回の回避策: `users.organization_id` を nullable にし、`belongs_to :organization, optional: true` としたうえで、認証・招待・組織選択の判定を `organization_memberships.active` 起点へ移した。

## 2026-07-25: 招待承諾と登録用 magic link の状態混同

- 状況: 新規登録用 invite と、既存ユーザーによる追加組織参加を同じ `organization_invites` 周辺の状態で扱っていた。
- 困った点: `stand_by_user`、`used_at`、`EmailAuthentication.used_at`、`OrganizationMembership` の有無が同じサービス内に混在し、メール認証未完了と組織未所属を混同しやすかった。
- 改善されるとよい点: Active Record enum や state machine 相当の状態遷移を DB 制約・トランザクション・エラーコードと一体で表現できる標準機能があると、招待の `invited / accepted / revoked / expired` とメール認証の `issued / used / expired` を分離しやすい。
- 今回の回避策: 既存ユーザーの組織参加は `OrganizationInvitations::AcceptanceService` に分離し、登録用メール認証を要求しない API とした。エラーコードも `email_mismatch`、`already_member`、`invitation_expired` などに分けた。

## 2026-07-25: schema dump の整形差分

- 状況: migration 実行後、`db/schema.rb` の index 配列表記が広範囲に整形変更され、実質差分が見えにくくなった。
- 困った点: migration の意味ある差分と schema dumper の整形差分が混ざり、レビュー時に DB 変更の意図を追いにくい。
- 改善されるとよい点: Rails schema dumper と RuboCop の標準整形が衝突しないか、schema dump 専用の安定した canonical format がより明確に提供されるとよい。
- 今回の回避策: 意味のない index 配列の空白差分を戻し、schema 差分を migration version と対象カラム・index だけに絞った。

## 2026-07-25: API 追加と OpenAPI 追従

- 状況: Rails routes に API を追加したあと、`docs/api.yml` の追従漏れを `bin/ai-check` で検出した。
- 困った点: Rails の routing DSL と OpenAPI は別管理のため、Controller 実装・routes・API spec の同期が手作業になりやすい。
- 改善されるとよい点: Rails の route/controller/request spec から OpenAPI の path skeleton を安全に生成・更新できる標準的な仕組みがあるとよい。特に error response の `code` 一覧を実装から同期できると、クライアント実装の取りこぼしを減らせる。
- 今回の回避策: `bin/ai-check` の API spec チェックで漏れを検出し、`organization_invitations` の show / accept を `docs/api.yml` に追記した。

## 2026-07-25: Brakeman と enum role の mass assignment

- 状況: 招待作成 API で `role` を strong parameters に含めたところ、Brakeman が mass assignment の警告を出した。
- 困った点: enum の許可値を validation していても、権限に関わる属性は mass assignment として検出される。警告自体は妥当だが、安全な enum 代入パターンを毎回個別に書く必要がある。
- 改善されるとよい点: 権限属性などの sensitive enum に対して、許可値・代入権限・操作履歴をまとめて宣言できる Rails 標準の仕組みがあるとよい。
- 今回の回避策: `role` は strong parameters から外し、`OrganizationInvite.roles.key?` で明示確認した値だけを controller 内で代入した。

## 2026-07-27: AIチェック用シェルスクリプトのBashバージョン依存

- 状況: macOS環境で `bin/ai-check` を実行すると、内部の `bin/ai-lint-changed` が利用する `mapfile` を標準Bash 3.2で解釈できず、Lint開始前に終了した。
- 困った点: Ruby/Railsコードの検証結果ではなく開発端末のBashバージョンでチェック可否が変わり、通常の実行方法だけでは失敗原因を判別しにくい。
- 改善されるとよい点: Rails周辺の検証スクリプトがPOSIX shell互換の構文を使うか、必要なBashバージョンを起動時に検査して具体的な導入・再実行方法を表示するとよい。
- 今回の回避策: Homebrew Bashを明示して `bin/ai-check` と `bin/check` を実行する。

## 2026-08-22: Action Mailerの推移依存に対する脆弱性検出

- 状況: `bin/bundler-audit` が、Action Mailer経由で導入される `mail 2.9.0` のGHSA-mvxr-6m87-mv2qを検出し、CIが失敗した。
- 困った点: アプリケーションが直接指定していない推移依存であり、Rails本体のバージョンを変えなくても個別gemの更新が必要か、lockfileだけからは判断しにくかった。
- 改善されるとよい点: BundlerやRailsの依存更新支援が、脆弱な推移依存について互換性を保った最小更新候補と、その依存元を一度に提示できるとよい。
- 今回の回避策: `bundle update mail --conservative` で `mail` のみを修正版の2.9.1へ更新し、`bin/bundler-audit` とリポジトリ全体のチェックで互換性を確認する。

## 2026-08-28: parallel test のDB分離とfilesystem共有

- 状況: DriveItem ID から決定的に算出する Preview cache を追加し、Rails の process 並列テストで purge と生成を検証した。
- 困った点: Rails は test DB を worker ごとに分離するが filesystem root は自動では分離しないため、別 DB で同じ ID が採番され、ある worker の purge が別 worker の cache を削除した。
- 改善されるとよい点: Active Storage 以外の filesystem を使う test 向けに、parallel worker ID を含む一時 root と終了時 cleanup を Rails が共通設定として提供するとよい。
- 今回の回避策: `parallelize_setup` で `media_preview_root` を worker ごとに分離し、production の決定的な cache path は変更せずに filesystem を使うテスト間の干渉を防いだ。

### 2026-10-21: API-only Controller からのメール文面プレビュー

- 状況: デモ用ログインで実送信せず、既存の認証メールの text template を表示する処理を追加した。
- 困った点: `ActionController::API` を継承した `ApplicationController.renderer` に template を渡しても本文が描画されず、プレビュー生成に流用できなかった。
- 望ましい改善: API-only Controller が対応しない描画オプションを受け取った場合、非対応であることを明確に通知してほしい。
- 今回の回避策: `ActionView::Base` の view paths と assigns を明示し、既存メール template を直接描画する。URL が本文に含まれることをテストする。

### 2026-10-23: 複数リポジトリの作業で Ruby の選択が変わる

- 状況: Rails と連携する infra の一時 worktree で同じテストコマンドを実行した。
- 困った点: Rails 側の `.ruby-version` の適用範囲を離れると macOS 標準の Ruby 2.6 が選ばれ、既存コードの `filter_map` 等が利用できず多数の失敗となった。
- 望ましい改善: 複数 checkout をまたぐツールでも、必要な Ruby バージョンを実行前に明示・検証できる仕組みが望ましい。
- 今回の回避策: infra 側の検証は `RBENV_VERSION=3.4.9 rbenv exec ruby` で実行し、環境起因の失敗と実装の回帰を区別する。

### 2026-10-23: Minitest 6 の nil 比較ルール

- 状況: 有効・無効の両方を検証する feature flag テストで、期待値を条件式で `nil` に切り替えた。
- 困った点: Minitest 6 では `assert_equal nil, actual` が非推奨扱いからテスト失敗となり、値が一致していても意図を表せない。
- 望ましい改善: 期待値が条件式で決まる場合にも、適切な assertion を明確に案内する診断が維持されるとよい。
- 今回の回避策: `nil` を期待する分岐では `assert_nil` を明示する。
## 2026-10-23: Ruby 更新時の実行環境と公開状況の確認

- 状況: Ruby の指定をアプリ側へ集約し、infra がリリースの `.ruby-version` から実行環境を準備する構成へ変更した。
- 困った点: リリース外の `gem install` は global Ruby に Bundler を導入し得る。また、指定された Ruby 3.4.12 は公式リリース一覧・配布一覧で確認できず、実行環境の準備と動作検証ができない。
- 改善されるとよい点: バージョン宣言・配布の有無・Bundler の導入先を、更新前に一貫して検証できる仕組み。
- 今回の回避策: infra で Ruby・Gem の準備と Rails 起動検査を切り替え前に行い、旧 Ruby を保持する。アプリ側の Docker 指定も揃え、3.4.12 の公開と対象 Ruby での検証が済むまでは Draft PR とする。Gemfile.lock は Ruby 固定項目を持たず依存解決も変更しないため据え置く。

### 開発環境の native Gem ビルド

- 状況: 既存 Ruby 3.4.9 で不足 Gem を導入して既存チェックを実行した。
- 困った点: Homebrew の `ld` が選択され、システムの `libcrypt.so.1` を見つけられなかったが、mkmf は「開発ツールを導入する必要がある」と表示した。また PATH から mise を外すと reshim hook が終了時に失敗した。
- 改善されるとよい点: mkmf が検査失敗の根拠となるリンクエラーを要約し、Ruby 管理ツールの hook 失敗と Gem 導入の成否を分けて示すこと。
- 今回の回避策: Gem 導入時は Ubuntu 標準リンカーを選ぶ PATH を指定し、hook 失敗後に `bundle check` で依存 Gem の充足を確認した。既存 Ruby での `bin/ai-check` と `bin/check` は成功したが、3.4.12 での検証の代替とはしない。
