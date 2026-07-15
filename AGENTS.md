# AGENTS

- このリポジトリのテスト基盤は Minitest (`test/`, `test/test_helper.rb`)。
- 通常作業では `bin/ai-check`、最終確認では `bin/check` を使う。
- `.env`、credentials、本番 DB 設定には触れない。
- AI 用の自動化に `db:drop`、`db:reset`、`db:purge`、`db:seed:replant` を入れない。
