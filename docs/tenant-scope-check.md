# DriveItem のテナントスコープ検査

`bin/check-tenant-scope` は Rails / DB を起動せず、既存の RuboCop AST を使って
`app/` と `lib/` の全 `.rb` / `.rake` を検査する。
GitHub Actions の `tenant_scope` job、`bin/ai-check`、`bin/check` からも実行する。
PR #37 の狙いを参考にした独立実装で、アプリケーションの挙動や認可は変更しない。

## 判定

- `DriveItem` / `::DriveItem` から始まる呼び出しを、複数行や safe navigation を含めて解析する。
- 未知のクラスメソッドも scope の可能性があるため検査する。非 DB 操作の既知メソッドだけを除外する。
- 同じ呼び出し鎖で、実行前の `where`、`find_by`、`find_by!`、`exists?` に
  `organization_id:` / `organization:` の肯定的な Hash 条件があれば許可する。
- `where.not`、SQL 文字列、入れ子の Hash、`nil` は組織制約として認めない。
  `unscoped`、`unscope`、`rewhere`、`except`、`only`、`or`、`find_by_sql` を含む鎖は
  条件を保持すると保証できないため、組織条件があっても要レビューとする。
- `organization.drive_items` の関連経由の検索や `DriveItem.none` は許可する。
- コメント・文字列中のコード風テキストは無視するが、文字列展開内の実コードは検査する。

終了コードは成功 `0`、違反または未使用例外 `1`、構文・設定・読込エラー `2`。
空ファイル・コメントのみのファイルは正常とし、検査対象ファイルがゼロの場合はエラーにする。

## 既存の横断処理

管理者検索、組織間移動、ツリー境界検査、共有ストレージの残存参照確認、運用タスクには
既存の横断クエリがある。`config/tenant_scope_exceptions.yml` にファイル、式の完全一致、
必要な理由を記録する。例外は一回だけ適用するため、同じ呼び出しの複製は検査に失敗する。
行番号の移動は許容するが、式の変更・整形や削除時には例外も見直す。
未使用・重複・理由なしの例外はエラーとし、ファイル単位の除外や自動更新は設けない。

## 制約とレビュー

これは構文上のガードであり、認可の正当性を証明するものではない。
組織条件の値の由来・実行時の nil、他の定数への代入、`send` / `const_get`、
変数に保存した Relation の後続操作、Model 内の暗黙の `self`、任意の自作 scope の内部、
関連経由の `unscoped`、メソッド間のデータフローは追跡しない。
SQL や複数文で後から組織条件を付加する実装には誤検出があり得る。
既知の実行メソッドを考慮するが、未知の自作メソッドが先に DB を実行するかは判定できない。
例外に登録した式の周囲の認可条件が変わっても自動検出できないため、認可の変更時は
関連テストと例外理由をレビューする。通常は認可済みの組織の `drive_items` 関連を使う。

検査器のテストは以下で DB なしに実行できる。

```sh
bundle exec ruby test/lib/tenant_scope_checker_test.rb
bundle exec ruby test/lib/tenant_scope_runner_test.rb
bin/check-tenant-scope
```
