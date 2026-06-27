# DB設計メモ：マルチテナント型ファイルサーバー

## 基本方針

## テーブル構成

### organizations

```text
id
name
created_at
updated_at
```

### users

```text
id
organization_id
email
name
created_at
updated_at
```

### drive_items

ファイルとディレクトリは同じテーブルで管理する

```text
id
organization_id
parent_id
name
item_type ディレクトリ or ファイルフラグ
extension ファイル拡張子(ディレクトリはdir)
blob_path
hash
created_at
updated_at
```

### drive_item_access_logs

閲覧日関係

```text
id
organization_id
user_id
drive_item_id
action view / download / preview
accessed_at
created_at
```

### organization_invites

招待コード

```text
id
organization_id
code
expires_at
used_at
created_at
updated_at
```

### drive_permissions

ファイルの権限

```text
id
drive_item_id
user_id
permission
created_at
updated_at
```

## ERイメージ

```text
Organization
    │
    ├── User
    │
    ├── OrganizationInvite
    │
    └── DriveItem
             │
             └── parent_id → DriveItem
```

## フォルダ構造の例

```text
/
└── 大学
    └── レポート
        └── report.pdf
```

DB上では次のように持つ。

```text
id | parent_id | name       | item_type
---|-----------|------------|----------
1  | NULL      | 大学        | folder
2  | 1         | レポート    | folder
3  | 2         | report.pdf | file
```

画面表示時に次のようなパスを組み立てる。

```text
/大学/レポート/report.pdf
```

## フルパスを保存しない理由

パスの変更時に効率をよくするため
たとえば

```sql
UPDATE drive_items
SET name = '課題'
WHERE id = 2;
```
