# Architecture

## Test Framework
- Minitest
- Root: `test/`
- Helper: `test/test_helper.rb`

## Controllers
- `ApplicationController` - API 共通のベースコントローラ
- `DriveItemsController` - ドライブ項目の一覧、作成、移動、削除、復元を扱う
- `EmailAuthenticationsController` - メール認証リンクの発行と検証を扱う

## Models
- `Organization` - ユーザー、招待、ドライブ項目を束ねる組織
- `User` - Devise 認証を持つ組織所属ユーザー
- `DriveItem` - ファイル/ディレクトリを表す階層オブジェクト
- `DrivePermission` - ユーザーとドライブ項目の権限付与
- `DriveItemAccessLog` - ドライブ項目アクセスの記録
- `OrganizationInvite` - 組織招待と stand-by 状態の管理
- `EmailAuthentication` - メール認証トークンと有効期限の管理
- `ApplicationRecord` - Active Record 共通ベース

## Services
- `app/services` は未作成

## Mailers
- `ApplicationMailer` - 共通メーラーベース
- `EmailAuthenticationMailer` - 認証リンク送信

## Jobs
- `ApplicationJob` - Active Job 共通ベース
