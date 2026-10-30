require "rubocop"

module TenantScope
  # Rails を起動せず、DriveItem 定数から始まる呼び出し鎖だけを検査する。
  # 変数への代入やメソッド間のデータフローは追跡しない。
  class Checker
    Finding = Data.define(:path, :line, :column, :source)
    Result = Data.define(:findings, :errors)

    # DB を検索しない既知のクラスメソッドだけを除外する。
    # 未知のメソッドは新規 scope の可能性があるため検査対象に残す。
    UTILITIES = %i[new storage_root storage_relative_path_for valid_storage_key? item_types].freeze
    RESETS = %i[unscoped unscope rewhere except only or].freeze
    EXECUTES = /\A(find(?!_by_sql)|first|last|take|sole|exists\?|count|sum|average|minimum|maximum|pluck|pick|ids|to_a|load|each|update|delete|destroy|insert|create)/

    def check(source, path: "(source)")
      parsed = RuboCop::AST::ProcessedSource.new(source.dup.freeze, RUBY_VERSION.to_f, path)
      errors = parsed.diagnostics.select { |diagnostic| %i[error fatal].include?(diagnostic.level) }
      return Result.new([], errors.map(&:render)) if errors.any?

      findings = []
      parsed.ast&.each_node(:send, :csend) do |node|
        next unless drive_item_constant?(node.receiver)
        next if UTILITIES.include?(node.method_name)

        chain = call_chain(node)
        next if scoped?(chain)

        expression = chain.last.location.expression
        findings << Finding.new(path, expression.line, expression.column + 1, expression.source)
      end
      Result.new(findings, [])
    end

    private

    def drive_item_constant?(node)
      node&.const_type? && [ "DriveItem", "::DriveItem" ].include?(node.const_name)
    end

    def call_chain(node)
      chain = [ node ]
      cursor = node
      while (parent = cursor.parent)
        if (parent.send_type? || parent.csend_type?) && parent.receiver.equal?(cursor)
          chain << parent
        elsif !(parent.block_type? && parent.send_node.equal?(cursor))
          break
        end
        cursor = parent
      end
      chain
    end

    # 後続の where で、既に実行済みの find や消去された条件を安全扱いしない。
    # where.not、SQL 文字列、nil の組織指定も肯定的な組織制約とはみなさない。
    def scoped?(chain)
      return false if chain.any? { |call| RESETS.include?(call.method_name) || call.method_name == :find_by_sql }
      return true if chain.first.method_name == :none

      chain.each do |call|
        return true if organization_filter?(call)
        return false if EXECUTES.match?(call.method_name.to_s)
      end
      false
    end

    def organization_filter?(call)
      return false unless %i[where find_by find_by! exists?].include?(call.method_name)

      call.arguments.any? do |argument|
        argument.hash_type? && argument.pairs.any? do |pair|
          key = pair.key
          (key.sym_type? || key.str_type?) && %w[organization organization_id].include?(key.value.to_s) &&
            !pair.value.nil_type?
        end
      end
    end
  end
end
