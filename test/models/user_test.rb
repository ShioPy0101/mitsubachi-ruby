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
end
