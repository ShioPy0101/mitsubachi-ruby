require "set"

module DriveItems
  # 同一 organization・同一階層にある active item の名前競合を扱う query object。
  #
  # 存在判定と候補名生成が別々の organization scope を参照すると、別 tenant の名前を
  # 候補へ混ぜたり、実際には再衝突する名前を返したりするため、両方を同じ入口へ集約する。
  class NameConflict
    MESSAGE = "同じ名前のファイルまたはフォルダーが存在します。"

    def initialize(organization:, parent_id:, name:, extension:, excluding_id: nil)
      @organization = organization
      @parent_id = parent_id
      @name = name
      @extension = extension
      @excluding_id = excluding_id
    end

    def conflict?
      return @conflict if defined?(@conflict)

      @conflict = sibling_scope.exists?(name: @name)
    end

    def details
      candidate = suggested_name
      {
        code: :duplicate_name,
        message: MESSAGE,
        field: "name",
        conflicting_name: filename(@name),
        duplicate_kind: "name",
        suggested_name: candidate,
        suggested_filename: filename(candidate)
      }
    end

    def filename(name = @name)
      @extension.present? ? "#{name}.#{@extension}" : name
    end

    private

    def suggested_name
      existing_names = sibling_scope.pluck(:name).to_set
      return @name unless existing_names.include?(@name)

      index = 1
      loop do
        candidate = "#{@name}（#{index}）"
        return candidate unless existing_names.include?(candidate)

        index += 1
      end
    end

    def sibling_scope
      scope = @organization.drive_items.active.where(parent_id: @parent_id, extension: @extension)
      @excluding_id.present? ? scope.where.not(id: @excluding_id) : scope
    end
  end
end
