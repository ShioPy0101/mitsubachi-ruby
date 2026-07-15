# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_16_020000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id", null: false
    t.jsonb "change_set", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.bigint "organization_id", null: false
    t.bigint "target_id", null: false
    t.string "target_type", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.index [ "action" ], name: "index_admin_audit_logs_on_action"
    t.index [ "actor_user_id" ], name: "index_admin_audit_logs_on_actor_user_id"
    t.index [ "created_at" ], name: "index_admin_audit_logs_on_created_at"
    t.index [ "organization_id" ], name: "index_admin_audit_logs_on_organization_id"
    t.index [ "target_type", "target_id" ], name: "index_admin_audit_logs_on_target_type_and_target_id"
  end

  create_table "drive_item_access_logs", force: :cascade do |t|
    t.string "action"
    t.datetime "created_at", null: false
    t.bigint "drive_item_id"
    t.string "ip_address", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at"
    t.bigint "organization_id", null: false
    t.string "request_id", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.bigint "user_id", null: false
    t.index [ "drive_item_id", "occurred_at" ], name: "index_access_logs_on_item_and_accessed_at"
    t.index [ "drive_item_id" ], name: "index_drive_item_access_logs_on_drive_item_id"
    t.index [ "organization_id", "user_id", "drive_item_id", "action", "occurred_at" ], name: "index_drive_item_access_logs_on_stream_dedupe_lookup"
    t.index [ "organization_id" ], name: "index_drive_item_access_logs_on_organization_id"
    t.index [ "user_id", "occurred_at" ], name: "index_access_logs_on_user_and_accessed_at"
    t.index [ "user_id" ], name: "index_drive_item_access_logs_on_user_id"
  end

  create_table "drive_items", force: :cascade do |t|
    t.string "blob_path"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "extension"
    t.string "file_hash"
    t.bigint "file_size"
    t.integer "item_type"
    t.string "name"
    t.bigint "organization_id", null: false
    t.bigint "owner_user_id", null: false
    t.bigint "parent_id"
    t.string "storage_key"
    t.datetime "updated_at", null: false
    t.index [ "deleted_at" ], name: "index_drive_items_on_deleted_at"
    t.index [ "organization_id", "parent_id", "name", "extension" ], name: "index_active_drive_items_on_org_parent_name_extension", unique: true, where: "(deleted_at IS NULL)"
    t.index [ "organization_id" ], name: "index_drive_items_on_organization_id"
    t.index [ "owner_user_id" ], name: "index_drive_items_on_owner_user_id"
    t.index [ "parent_id" ], name: "index_drive_items_on_parent_id"
  end

  create_table "drive_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "drive_item_id", null: false
    t.integer "permission"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index [ "drive_item_id" ], name: "index_drive_permissions_on_drive_item_id"
    t.index [ "user_id" ], name: "index_drive_permissions_on_user_id"
  end

  create_table "email_authentications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "expires_at"
    t.bigint "organization_invite_id"
    t.string "token"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index [ "organization_invite_id" ], name: "index_email_authentications_on_organization_invite_id"
    t.index [ "token" ], name: "index_email_authentications_on_token", unique: true
  end

  create_table "organization_invites", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "organization_id", null: false
    t.datetime "stand_by_at"
    t.bigint "stand_by_user_id"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "used_by_user_id"
    t.index [ "code" ], name: "index_organization_invites_on_code", unique: true
    t.index [ "organization_id" ], name: "index_organization_invites_on_organization_id"
    t.index [ "stand_by_user_id" ], name: "index_organization_invites_on_stand_by_user_id"
    t.index [ "used_by_user_id" ], name: "index_organization_invites_on_used_by_user_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "last_sign_in_at"
    t.string "name"
    t.bigint "organization_id", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "role", default: 0, null: false
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email_unique", unique: true
    t.index [ "last_sign_in_at" ], name: "index_users_on_last_sign_in_at"
    t.index [ "organization_id" ], name: "index_users_on_organization_id"
    t.index [ "reset_password_token" ], name: "index_users_on_reset_password_token", unique: true
    t.index [ "role" ], name: "index_users_on_role"
    t.index [ "suspended_at" ], name: "index_users_on_suspended_at"
  end

  add_foreign_key "admin_audit_logs", "organizations"
  add_foreign_key "admin_audit_logs", "users", column: "actor_user_id"
  add_foreign_key "drive_item_access_logs", "drive_items", on_delete: :nullify
  add_foreign_key "drive_item_access_logs", "organizations"
  add_foreign_key "drive_item_access_logs", "users"
  add_foreign_key "drive_items", "drive_items", column: "parent_id"
  add_foreign_key "drive_items", "organizations"
  add_foreign_key "drive_items", "users", column: "owner_user_id"
  add_foreign_key "drive_permissions", "drive_items"
  add_foreign_key "drive_permissions", "users"
  add_foreign_key "email_authentications", "organization_invites"
  add_foreign_key "organization_invites", "organizations"
  add_foreign_key "organization_invites", "users", column: "stand_by_user_id"
  add_foreign_key "organization_invites", "users", column: "used_by_user_id"
  add_foreign_key "users", "organizations"
end
