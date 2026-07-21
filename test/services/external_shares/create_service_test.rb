require "test_helper"
require "digest"

class ExternalShares::CreateServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @organization = @user.organization
    @folder = drive_items(:child_folder)
    @file = drive_items(:child_file)
    @nested_file = DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: @folder,
      name: "nested",
      item_type: "file",
      extension: "txt",
      storage_key: "nested-#{SecureRandom.uuid}.txt",
      blob_path: "drive_items/nested.txt",
      file_hash: Digest::SHA256.hexdigest("nested"),
      file_size: 6,
      content_type: "text/plain"
    )
  end

  test "複数のDriveItemを1つのsnapshot共有として作成する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "納品データ",
        drive_item_ids: [ @folder.id, @file.id, @nested_file.id ],
        folder_share_mode: "snapshot",
        allow_download: true,
        allow_bulk_download: true
      }
    ).call

    assert result.success?
    share = result.external_share
    assert_predicate result.raw_token, :present?
    assert_equal "snapshot", share.folder_share_mode

    expected_ids = [
      @file,
      @folder,
      drive_items(:grandchild_folder),
      @nested_file
    ].map(&:id).sort
    actual_ids = share.external_share_items.pluck(:drive_item_id).sort

    assert_equal expected_ids, actual_ids
    assert_equal actual_ids.uniq, actual_ids
    assert_not_includes actual_ids, drive_items(:one).id
  end

  test "dynamic共有では選択されたルートだけを保存する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "追従共有",
        drive_item_ids: [ @folder.id ],
        folder_share_mode: "dynamic"
      }
    ).call

    assert result.success?
    assert_equal [ @folder.id ], result.external_share.external_share_items.pluck(:drive_item_id)
  end

  test "他organizationのDriveItemが混在すると作成しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "invalid",
        drive_item_ids: [ @file.id, drive_items(:two).id ],
        folder_share_mode: "snapshot"
      }
    ).call

    assert_not result.success?
    assert_equal :not_found, result.status
    assert_equal 0, ExternalShare.count
  end

  test "生トークンはDBへ保存しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "token",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot"
      }
    ).call

    assert result.success?
    assert_not_equal result.raw_token, result.external_share.token_digest
    assert_equal Digest::SHA256.hexdigest(result.raw_token), result.external_share.token_digest
  end

  test "パスワード保護ありではランダムパスワードを生成してハッシュだけ保存する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "protected",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot",
        password_protected: true
      }
    ).call

    assert result.success?
    assert_match(/\A[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789]{16}\z/, result.generated_password)
    assert result.external_share.password_required?
    assert_not_equal result.generated_password, result.external_share.password_digest
    assert result.external_share.authenticate(result.generated_password)
  end

  test "生成した同じ平文パスワードをレスポンスとハッシュ保存に使う" do
    plain_password = "AbCdEfGh23456789"
    password_generator = FixedPasswordGenerator.new(plain_password)

    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "protected fixed",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot",
        password_protected: true
      },
      password_generator: password_generator
    ).call

    assert result.success?
    assert_equal 1, password_generator.call_count
    assert_equal plain_password, result.generated_password
    assert_not_equal plain_password, result.external_share.password_digest
    assert result.external_share.authenticate(plain_password)
    assert_not result.external_share.authenticate("#{plain_password}x")
  end

  test "パスワード保護なしではパスワードを生成しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "public",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot",
        password_protected: false
      }
    ).call

    assert result.success?
    assert_nil result.generated_password
    assert_not result.external_share.password_required?
  end

  test "任意パスワード指定では保護パスワードを保存しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "legacy password ignored",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot",
        password: "creator-password"
      }
    ).call

    assert result.success?
    assert_nil result.generated_password
    assert_not result.external_share.password_required?
  end

  test "複数共有の生成パスワードは異なる" do
    results = 2.times.map do |index|
      ExternalShares::CreateService.new(
        user: @user,
        params: {
          name: "protected #{index}",
          drive_item_ids: [ @file.id ],
          folder_share_mode: "snapshot",
          password_protected: true
        }
      ).call
    end

    assert results.all?(&:success?)
    assert_equal results.map(&:generated_password).uniq, results.map(&:generated_password)
  end

  class FixedPasswordGenerator
    attr_reader :call_count

    def initialize(password)
      @password = password
      @call_count = 0
    end

    def generate
      @call_count += 1
      @password
    end
  end
end
