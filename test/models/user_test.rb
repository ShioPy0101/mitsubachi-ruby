require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "email uniqueness validation is case insensitive" do
    User.create!(
      organization: organizations(:one),
      email: "Test@example.com",
      password: "password123"
    )

    duplicate = User.new(
      organization: organizations(:one),
      email: "test@example.com",
      password: "password123"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "email is stripped before save" do
    user = User.create!(
      organization: organizations(:one),
      email: "  spaced@example.com  ",
      password: "password123"
    )

    assert_equal "spaced@example.com", user.email
  end

  test "email is downcased before save" do
    user = User.create!(
      organization: organizations(:one),
      email: "LOWERCASE@example.com",
      password: "password123"
    )

    assert_equal "lowercase@example.com", user.email
  end

  test "database unique index rejects case-insensitive duplicates" do
    now = Time.current
    organization = organizations(:one)

    User.insert_all!([
      {
        organization_id: organization.id,
        email: "DbCase@example.com",
        encrypted_password: "password",
        created_at: now,
        updated_at: now
      }
    ])

    assert_raises ActiveRecord::RecordNotUnique do
      User.insert_all!([
        {
          organization_id: organization.id,
          email: "dbcase@example.com",
          encrypted_password: "password",
          created_at: now,
          updated_at: now
        }
      ])
    end
  end

  test "display_name is normalized and unique within organization" do
    user = users(:one)
    user.update!(display_name: "  表示名テスト  ")

    assert_equal "表示名テスト", user.display_name

    duplicate = User.new(
      organization: user.organization,
      email: "duplicate@example.com",
      password: "password123",
      display_name: "表示名テスト"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:display_name], "has already been taken"
  end

  test "display_name rejects control characters" do
    user = users(:one)
    user.display_name = "bad\nname"

    assert_not user.valid?
    assert_includes user.errors[:display_name], "に制御文字は使用できません"
  end
end
