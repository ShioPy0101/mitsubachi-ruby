require "yaml"
require_relative "checker"

module TenantScope
  # 例外はファイル・式の完全一致で一回だけ消費する。
  # 行番号の移動は許容するが、同じ違反の複製や不要になった例外は CI で拒否する。
  class Runner
    def initialize(root:, output: $stdout)
      @root = root
      @output = output
    end

    def run
      exceptions = load_exceptions
      findings = []
      errors = []
      paths = Dir.glob("{app,lib}/**/*.{rb,rake}", base: @root).sort
      raise ArgumentError, "No Ruby files found under app/ or lib/" if paths.empty?

      paths.each do |path|
        result = Checker.new.check(File.read(File.join(@root, path)), path: path)
        findings.concat(result.findings)
        errors.concat(result.errors)
      end
      errors.each { |error| @output.puts(error) }
      return 2 if errors.any?

      violations = findings.reject do |finding|
        index = exceptions.index { |entry| entry["path"] == finding.path && entry["source"] == finding.source }
        exceptions.delete_at(index) if index
      end
      violations.each do |finding|
        @output.puts "#{finding.path}:#{finding.line}:#{finding.column}: DriveItem のテナントスコープを確認してください"
        @output.puts "  #{finding.source}"
      end
      exceptions.each { |entry| @output.puts "Unused tenant scope exception: #{entry.fetch('path')}: #{entry.fetch('source')}" }
      @output.puts "Tenant scope: #{paths.size} files, #{violations.size} violations, #{exceptions.size} unused exceptions"
      violations.empty? && exceptions.empty? ? 0 : 1
    rescue Psych::Exception, ArgumentError, SystemCallError => error
      @output.puts "Tenant scope error: #{error.message}"
      2
    end

    private

    def load_exceptions
      entries = YAML.safe_load_file(File.join(@root, "config/tenant_scope_exceptions.yml"))
      unless entries.is_a?(Array) && entries.all? { |entry| valid_exception?(entry) }
        raise ArgumentError, "Each exception must have nonempty path, source and reason strings"
      end
      keys = entries.map { |entry| entry.values_at("path", "source") }
      raise ArgumentError, "Duplicate tenant scope exceptions" unless keys.uniq.size == keys.size

      entries
    end

    def valid_exception?(entry)
      entry.is_a?(Hash) && %w[path source reason].all? do |key|
        entry[key].is_a?(String) && !entry[key].strip.empty?
      end
    end
  end
end
