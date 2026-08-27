require "json"

# UploadResolutionPolicy は「競合カテゴリに対してユーザーが選んだ解決方法」を
# matrix で制約する値オブジェクト。UploadAttempt.state は変更せず、
# workflow 側が resolution_for の結果を event / action へ変換する。
class UploadResolutionPolicy
  class InvalidPolicy < StandardError; end

  # 内容一致は競合ではなくなったため、移行期間中は旧クライアントが送るルールを無視する。
  # 未知のカテゴリは従来どおり拒否し、入力ミスを見逃さない。
  DEPRECATED_IGNORED_CATEGORIES = %i[active_content_duplicate trash_content_duplicate].freeze

  CONFLICT_MATRIX = {
    duplicate_name: {
      default_resolution: nil,
      allowed_resolutions: %i[auto_rename skip],
      workflow_events: {
        auto_rename: :rename_and_retry,
        skip: :skip_upload
      },
      http_status: :conflict,
      error_code: :duplicate_name
    },
    invalid_parent: {
      default_resolution: nil,
      allowed_resolutions: %i[skip],
      workflow_events: {
        skip: :skip_upload
      },
      http_status: :not_found,
      error_code: :invalid_parent
    }
  }.freeze

  CATEGORIES = CONFLICT_MATRIX.keys.freeze
  RESOLUTIONS = CONFLICT_MATRIX.values.flat_map { |definition| definition.fetch(:allowed_resolutions) }.uniq.freeze
  SCOPES = %i[item batch].freeze
  PRECEDENCE = %i[item batch default].freeze

  Rule = Struct.new(:category, :resolution, :scope, :item_key, keyword_init: true)

  def self.from_params(params, default_item_key: nil)
    rules = []
    explicit_policy_present = params.key?(:upload_policy) || params.key?(:policy)
    if explicit_policy_present
      rules.concat(parse_upload_policy(params[:upload_policy] || params[:policy]))
    end

    # 旧multipart fieldは境界で item rule に正規化し、workflow内部では参照しない。
    legacy_rules = legacy_rules_from(params, default_item_key:)
    rules.concat(legacy_rules)
    new(rules)
  rescue InvalidPolicy
    raise
  rescue JSON::ParserError
    raise InvalidPolicy, "upload_policy must be valid JSON"
  end

  def self.legacy_rules_from(params, default_item_key:)
    rules = []
    if params[:name_conflict_action] == "auto_rename"
      rules << build_rule(
        category: :duplicate_name,
        resolution: :auto_rename,
        scope: :item,
        item_key: default_item_key,
        legacy: true
      )
    end
    rules
  end

  def self.parse_upload_policy(raw)
    return [] if raw.blank?

    value = raw.is_a?(String) ? JSON.parse(raw) : raw
    entries =
      if hash_like?(value) && value.to_h.key?("category")
        [ value ]
      elsif hash_like?(value)
        value.map { |category, resolution| { "category" => category, "resolution" => resolution, "scope" => "batch" } }
      elsif value.is_a?(Array)
        value
      else
        raise InvalidPolicy, "upload_policy must be an object or array"
      end

    entries.filter_map do |entry|
      canonical = canonical_hash(entry)
      next if DEPRECATED_IGNORED_CATEGORIES.include?(canonical["category"].to_s.to_sym)

      build_rule(
        category: canonical.fetch("category"),
        resolution: canonical.fetch("resolution"),
        scope: canonical.fetch("scope", "item"),
        item_key: canonical["item_key"] || canonical["itemKey"] || canonical["client_upload_id"] || canonical["clientUploadId"]
      )
    rescue KeyError => error
      raise InvalidPolicy, "upload_policy is missing #{error.key}"
    end
  end

  def self.build_rule(category:, resolution:, scope:, item_key: nil, legacy: false)
    category = category.to_sym
    resolution = resolution.to_sym
    scope = scope.to_sym
    item_key = item_key.to_s.presence

    raise InvalidPolicy, "unknown category #{category}" unless CATEGORIES.include?(category)
    raise InvalidPolicy, "unknown resolution #{resolution}" unless RESOLUTIONS.include?(resolution)
    raise InvalidPolicy, "unknown scope #{scope}" unless SCOPES.include?(scope)
    unless CONFLICT_MATRIX.fetch(category).fetch(:allowed_resolutions).include?(resolution)
      raise InvalidPolicy, "#{resolution} is not allowed for #{category}"
    end
    if scope == :item && item_key.blank?
      raise InvalidPolicy, "item scoped upload_policy requires item_key" unless legacy
    end

    Rule.new(category:, resolution:, scope:, item_key:)
  end

  def self.canonical_hash(value)
    raise InvalidPolicy, "upload_policy entries must be objects" unless hash_like?(value)

    value.to_h.transform_keys(&:to_s)
  end

  def self.hash_like?(value)
    value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
  end

  attr_reader :rules

  def initialize(rules)
    @rules = rules.freeze
    validate_conflicts!
  end

  def resolution_for(category, item_key:)
    category = category.to_sym
    item_key = item_key.to_s.presence
    item_rule = rules.select { |rule| rule.scope == :item && rule.category == category && rule.item_key == item_key }
    return item_rule.first.resolution if item_rule.any?

    batch_rule = rules.select { |rule| rule.scope == :batch && rule.category == category }
    return batch_rule.first.resolution if batch_rule.any?

    CONFLICT_MATRIX.fetch(category).fetch(:default_resolution)
  end

  def workflow_event_for(category, resolution)
    return nil if resolution.blank?

    CONFLICT_MATRIX.fetch(category.to_sym).fetch(:workflow_events).fetch(resolution.to_sym)
  end

  def as_json(*)
    rules.map do |rule|
      {
        category: rule.category,
        resolution: rule.resolution,
        scope: rule.scope,
        item_key: rule.item_key
      }.compact
    end
  end

  private

  def validate_conflicts!
    grouped = rules.group_by { |rule| [ rule.category, rule.scope, rule.item_key ] }
    grouped.each do |(_category, _scope, _item_key), same_priority_rules|
      resolutions = same_priority_rules.map(&:resolution).uniq
      raise InvalidPolicy, "conflicting upload_policy rules" if resolutions.size > 1
    end
  end
end
