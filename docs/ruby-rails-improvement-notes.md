# Ruby / Rails 改善メモ

Ruby 言語、Rails、Rails 周辺ツールに起因して実装・保守・検証が難しくなった点を記録する。新しい気づきがあれば、該当作業のコミットに含める。

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
- 改善されるとよい点: 権限属性などの sensitive enum に対して、許可値・代入権限・監査ログをまとめて宣言できる Rails 標準の仕組みがあるとよい。
- 今回の回避策: `role` は strong parameters から外し、`OrganizationInvite.roles.key?` で明示確認した値だけを controller 内で代入した。
