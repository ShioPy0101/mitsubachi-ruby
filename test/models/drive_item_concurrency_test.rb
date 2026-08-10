require "test_helper"

class DriveItemConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @organization = organizations(:one)
    @user = users(:one)
    @root = drive_items(:one)
    @created_ids = []
  end

  teardown do
    DriveItem.where(id: @created_ids).delete_all
    DriveItem.where("name LIKE ?", "parallel-%").delete_all
  end

  test "parallel same-content creates are allowed when names differ" do
    hash = Digest::SHA256.hexdigest("parallel-content")
    results = create_files_in_parallel(
      [
        { name: "parallel-content-a", storage_key: "#{SecureRandom.uuid}.txt", file_hash: hash },
        { name: "parallel-content-b", storage_key: "#{SecureRandom.uuid}.txt", file_hash: hash }
      ]
    )

    assert_equal 2, results.count { |result| result == :created }
    assert_equal 2, DriveItem.active.file.where(organization: @organization, file_hash: hash).count
  end

  test "active name unique index prevents parallel same-name creates" do
    name = "parallel-name-#{SecureRandom.hex(4)}"
    results = create_files_in_parallel(
      [
        { name: name, storage_key: "#{SecureRandom.uuid}.txt", file_hash: Digest::SHA256.hexdigest("parallel-name-a") },
        { name: name, storage_key: "#{SecureRandom.uuid}.txt", file_hash: Digest::SHA256.hexdigest("parallel-name-b") }
      ]
    )

    assert_equal 1, results.count { |result| result == :created }
    assert_equal 1, results.count { |result| result.is_a?(ActiveRecord::RecordNotUnique) }
    assert_equal 1, DriveItem.active.file.where(organization: @organization, parent: @root, name: name, extension: "txt").count
  end

  test "parent lock serializes parallel child create and trash" do
    parent = DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: @root,
      name: "parallel-trash-parent-#{SecureRandom.hex(4)}",
      item_type: "directory"
    )
    @created_ids << parent.id
    child_id = Queue.new
    parent_locked = Queue.new

    upload_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          DriveItems::LockPlan.new(organization: @organization).lock_active_parent!(parent.id)
          parent_locked << true
          child = create_file!(
            name: "parallel-trash-child",
            parent: parent,
            storage_key: "#{SecureRandom.uuid}.txt",
            file_hash: Digest::SHA256.hexdigest("parallel-trash-child")
          )
          child_id << child.id
        end
      end
    end

    trash_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        parent_locked.pop
        DriveItems::TrashService.new(drive_items: [ parent ]).call
      end
    end

    upload_thread.join
    trash_thread.join

    child = DriveItem.find(child_id.pop)
    if parent.reload.deleted_at.present?
      assert child.reload.deleted_at.present?
      assert_empty DriveItem.active.where(parent_id: parent.id)
    else
      assert_nil child.reload.deleted_at
    end
  end

  private

  def create_files_in_parallel(attributes)
    start = Queue.new
    results = Queue.new
    threads = attributes.map do |attrs|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          create_file!(attrs)
          results << :created
        rescue ActiveRecord::RecordNotUnique => error
          results << error
        end
      end
    end

    attributes.size.times { start << true }
    threads.each(&:join)
    attributes.size.times.map { results.pop }
  end

  def create_file!(attrs)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: attrs.fetch(:parent, @root),
      name: attrs.fetch(:name),
      item_type: "file",
      extension: "txt",
      storage_key: attrs.fetch(:storage_key),
      blob_path: attrs.fetch(:storage_key),
      file_hash: attrs.fetch(:file_hash),
      file_size: 1,
      content_type: "text/plain"
    ).tap { |item| @created_ids << item.id }
  end
end
