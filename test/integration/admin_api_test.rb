require "test_helper"

class AdminApiTest < ActionDispatch::IntegrationTest
  setup do
    @organization = organizations(:one)
    @other_organization = organizations(:two)
    @member = users(:one)
    @other_member = users(:two)
    @system_admin = create_user(role: :system_admin, organization: @organization, email: "system-admin@example.com")
    @organization_admin = create_user(role: :organization_admin, organization: @organization, email: "org-admin@example.com")
    @managed_user = create_user(role: :member, organization: @organization, email: "managed@example.com")
    @other_org_user = create_user(role: :member, organization: @other_organization, email: "other-managed@example.com")
    @drive_item = drive_items(:child_file)
    @other_drive_item = drive_items(:two)
  end

  test "未認証ユーザーは管理APIを利用できない" do
    get api_v1_admin_dashboard_url

    assert_response :unauthorized
  end

  test "member は管理APIを利用できない" do
    sign_in @member

    get api_v1_admin_dashboard_url

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "system_admin は全組織を参照できる" do
    sign_in @system_admin

    get api_v1_admin_organizations_url, params: { per_page: 100, sort: "created_at", direction: "asc" }

    assert_response :ok
    organization_ids = response.parsed_body.fetch("data").pluck("id")
    assert_includes organization_ids, @organization.id
    assert_includes organization_ids, @other_organization.id
    assert_equal 1, response.parsed_body.dig("meta", "current_page")
  end

  test "organization_admin は自組織を参照できる" do
    sign_in @organization_admin

    get api_v1_admin_organization_url(@organization)

    assert_response :ok
    assert_equal @organization.id, response.parsed_body.dig("data", "id")
  end

  test "organization_admin は他組織を参照できない" do
    sign_in @organization_admin

    get api_v1_admin_organization_url(@other_organization)

    assert_response :not_found
  end

  test "未認証ユーザーはorganizationを作成できない" do
    post api_v1_admin_organizations_url, params: {
      organization: { name: "Acme Inc." }
    }

    assert_response :unauthorized
  end

  test "organization_admin はorganizationを作成できない" do
    sign_in @organization_admin

    post api_v1_admin_organizations_url, params: {
      organization: { name: "Acme Inc." }
    }

    assert_response :forbidden
    assert_equal(
      {
        "code" => "forbidden",
        "message" => "この操作を実行する権限がありません"
      },
      response.parsed_body.fetch("error")
    )
  end

  test "system_admin はorganizationを作成でき監査ログが作成される" do
    sign_in @system_admin

    assert_difference "Organization.count", 1 do
      assert_difference "AdminAuditLog.where(action: 'organization.create').count", 1 do
        post api_v1_admin_organizations_url, params: {
          organization: { name: "Acme Inc." }
        }
      end
    end

    assert_response :created
    data = response.parsed_body.fetch("data")
    organization = Organization.find(data.fetch("id"))
    assert_equal "Acme Inc.", organization.name
    assert_equal(
      {
        "id" => organization.id,
        "name" => "Acme Inc.",
        "users_count" => 0,
        "drive_items_count" => 0,
        "storage_bytes" => 0,
        "created_at" => organization.created_at.iso8601(3),
        "updated_at" => organization.updated_at.iso8601(3)
      },
      data
    )

    audit_log = AdminAuditLog.find_by!(
      action: "organization.create",
      target_type: "Organization",
      target_id: organization.id
    )
    assert_equal organization, audit_log.organization
    assert_equal({ "name" => [ nil, "Acme Inc." ] }, audit_log.change_set)
  end

  test "system_admin のorganization作成は入力エラーを返す" do
    sign_in @system_admin

    assert_no_difference "Organization.count" do
      post api_v1_admin_organizations_url, params: {
        organization: { name: "" }
      }
    end

    assert_response :unprocessable_entity
    assert_equal({ "errors" => [ "Name can't be blank" ] }, response.parsed_body)
  end

  test "system_admin は任意のorganizationへ招待コードを発行できる" do
    sign_in @system_admin

    assert_difference "OrganizationInvite.count", 1 do
      assert_difference "AdminAuditLog.where(action: 'organization_invite.create').count", 1 do
        assert_difference "AuditEvent.where(action: 'organization_invite.create').count", 1 do
          post api_v1_admin_organization_invites_url, params: {
            organization_invite: {
              organization_id: @other_organization.id,
              expires_at: 3.days.from_now.iso8601
            }
          }
        end
      end
    end

    assert_response :created
    data = response.parsed_body.fetch("data")
    invite = OrganizationInvite.find(data.fetch("id"))
    assert_equal @other_organization, invite.organization
    assert_equal invite.code, data.fetch("code")
    assert invite.expires_at.present?
  end

  test "organization_admin は自organizationへ招待コードを発行できる" do
    sign_in @organization_admin

    post api_v1_admin_organization_invites_url, params: {
      organization_invite: {}
    }

    assert_response :created
    invite = OrganizationInvite.find(response.parsed_body.dig("data", "id"))
    assert_equal @organization, invite.organization
  end

  test "organization_admin は他organizationへ招待コードを発行できない" do
    sign_in @organization_admin

    assert_no_difference "OrganizationInvite.count" do
      post api_v1_admin_organization_invites_url, params: {
        organization_invite: { organization_id: @other_organization.id }
      }
    end

    assert_response :forbidden
  end

  test "organization_admin は system_admin へ昇格させられない" do
    sign_in @organization_admin

    patch api_v1_admin_user_url(@managed_user), params: {
      user: { role: "system_admin" }
    }

    assert_response :forbidden
    assert_not @managed_user.reload.system_admin?
  end

  test "organization_admin は別organizationへユーザーを移動できない" do
    sign_in @organization_admin

    patch api_v1_admin_user_url(@managed_user), params: {
      user: { organization_id: @other_organization.id }
    }

    assert_response :forbidden
    assert_equal @organization.id, @managed_user.reload.organization_id
  end

  test "最後のsystem_adminは停止できない" do
    sign_in @system_admin

    patch suspend_api_v1_admin_user_url(@system_admin)

    assert_response :forbidden
    assert_not @system_admin.reload.suspended?
  end

  test "Userの停止と解除で監査ログが作成される" do
    create_user(role: :system_admin, organization: @other_organization, email: "second-system@example.com")
    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'user.suspend').count", 1 do
      patch suspend_api_v1_admin_user_url(@managed_user)
    end

    assert_response :ok
    assert @managed_user.reload.suspended?

    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'user.unsuspend').count", 1 do
      patch unsuspend_api_v1_admin_user_url(@managed_user)
    end

    assert_response :ok
    assert_not @managed_user.reload.suspended?
  end

  test "DriveItemの削除と復元で監査ログが作成される" do
    sign_in @organization_admin

    assert_difference "AdminAuditLog.where(action: 'drive_item.delete').count", 1 do
      delete api_v1_admin_drive_item_url(@drive_item)
    end

    assert_response :ok
    assert @drive_item.reload.deleted_at.present?

    sign_in @organization_admin

    assert_difference "AdminAuditLog.where(action: 'drive_item.restore').count", 1 do
      patch restore_api_v1_admin_drive_item_url(@drive_item)
    end

    assert_response :ok
    assert_nil @drive_item.reload.deleted_at
  end

  test "organization_admin は他組織のDriveItemを操作できない" do
    sign_in @organization_admin

    delete api_v1_admin_drive_item_url(@other_drive_item)

    assert_response :not_found
    assert_nil @other_drive_item.reload.deleted_at
  end

  test "検索 絞り込み 並び替え ページネーションが利用できる" do
    sign_in @system_admin

    get api_v1_admin_users_url, params: {
      q: "managed",
      role: "member",
      organization_id: @organization.id,
      status: "active",
      sort: "email",
      direction: "asc",
      page: 1,
      per_page: 1
    }

    assert_response :ok
    assert_equal 1, response.parsed_body.fetch("data").size
    assert_equal 1, response.parsed_body.dig("meta", "per_page")
    assert_operator response.parsed_body.dig("meta", "total_count"), :>=, 1
  end

  test "不正なsortパラメータは安全に既定値へフォールバックする" do
    sign_in @system_admin

    get api_v1_admin_drive_items_url, params: {
      sort: "name; DROP TABLE users",
      per_page: 2
    }

    assert_response :ok
    assert_equal 2, response.parsed_body.fetch("data").size
  end

  test "Organization更新で監査ログが作成される" do
    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'organization.update').count", 1 do
      patch api_v1_admin_organization_url(@organization), params: {
        organization: { name: "Updated Organization" }
      }
    end

    assert_response :ok
    assert_equal "Updated Organization", @organization.reload.name
  end

  test "organization_admin は自組織の監査ログだけを閲覧できる" do
    own_log = AdminAuditLog.create!(
      actor_user: @organization_admin,
      organization: @organization,
      action: "user.update",
      target_type: "User",
      target_id: @managed_user.id
    )
    other_log = AdminAuditLog.create!(
      actor_user: @system_admin,
      organization: @other_organization,
      action: "user.update",
      target_type: "User",
      target_id: @other_org_user.id
    )

    sign_in @organization_admin
    get api_v1_admin_audit_logs_url, params: { per_page: 100 }

    assert_response :ok
    ids = response.parsed_body.fetch("data").pluck("id")
    assert_includes ids, own_log.id
    assert_not_includes ids, other_log.id

    sign_in @organization_admin

    get api_v1_admin_audit_log_url(other_log)

    assert_response :not_found
  end

  test "system_admin は全般監査イベントを閲覧できる" do
    own_event = AuditEvent.create!(
      organization: @organization,
      actor_user: @organization_admin,
      action: "test.own",
      outcome: "success",
      occurred_at: Time.current
    )
    other_event = AuditEvent.create!(
      organization: @other_organization,
      actor_user: @other_org_user,
      action: "test.other",
      outcome: "success",
      occurred_at: Time.current
    )

    sign_in @system_admin
    get api_v1_admin_audit_events_url, params: { per_page: 100 }

    assert_response :ok
    ids = response.parsed_body.fetch("data").pluck("id")
    assert_includes ids, own_event.id
    assert_includes ids, other_event.id
  end

  test "organization_admin は自組織の全般監査イベントだけを閲覧できる" do
    own_event = AuditEvent.create!(
      organization: @organization,
      actor_user: @organization_admin,
      action: "test.own",
      outcome: "success",
      occurred_at: Time.current
    )
    other_event = AuditEvent.create!(
      organization: @other_organization,
      actor_user: @other_org_user,
      action: "test.other",
      outcome: "success",
      occurred_at: Time.current
    )

    sign_in @organization_admin
    get api_v1_admin_audit_events_url, params: { per_page: 100 }

    assert_response :ok
    ids = response.parsed_body.fetch("data").pluck("id")
    assert_includes ids, own_event.id
    assert_not_includes ids, other_event.id

    sign_in @organization_admin

    get api_v1_admin_audit_event_url(other_event)

    assert_response :not_found
  end

  private

  def create_user(role:, organization:, email:)
    User.create!(
      organization: organization,
      email: email,
      name: email.split("@").first,
      password: "password123",
      role: role
    )
  end
end
