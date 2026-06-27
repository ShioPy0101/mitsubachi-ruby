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

ActiveRecord::Schema[8.1].define(version: 2026_06_27_205102) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "drive_items", force: :cascade do |t|
    t.string "blob_path"
    t.datetime "created_at", null: false
    t.string "file_hash"
    t.integer "item_type"
    t.string "name"
    t.bigint "organization_id", null: false
    t.bigint "owner_user_id", null: false
    t.bigint "parent_id"
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_drive_items_on_organization_id"
    t.index ["owner_user_id"], name: "index_drive_items_on_owner_user_id"
    t.index ["parent_id"], name: "index_drive_items_on_parent_id"
  end

  create_table "drive_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "drive_item_id", null: false
    t.integer "permission"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["drive_item_id"], name: "index_drive_permissions_on_drive_item_id"
    t.index ["user_id"], name: "index_drive_permissions_on_user_id"
  end

  create_table "email_authentications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "expires_at"
    t.string "token"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
  end

  create_table "email_verification_codes", force: :cascade do |t|
    t.string "code_digest"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_email_verification_codes_on_user_id"
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
    t.index ["code"], name: "index_organization_invites_on_code", unique: true
    t.index ["organization_id"], name: "index_organization_invites_on_organization_id"
    t.index ["stand_by_user_id"], name: "index_organization_invites_on_stand_by_user_id"
    t.index ["used_by_user_id"], name: "index_organization_invites_on_used_by_user_id"
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
    t.string "name"
    t.bigint "organization_id", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["organization_id"], name: "index_users_on_organization_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "drive_items", "drive_items", column: "parent_id"
  add_foreign_key "drive_items", "organizations"
  add_foreign_key "drive_items", "users", column: "owner_user_id"
  add_foreign_key "drive_permissions", "drive_items"
  add_foreign_key "drive_permissions", "users"
  add_foreign_key "email_verification_codes", "users"
  add_foreign_key "organization_invites", "organizations"
  add_foreign_key "organization_invites", "users", column: "stand_by_user_id"
  add_foreign_key "organization_invites", "users", column: "used_by_user_id"
  add_foreign_key "users", "organizations"
end
