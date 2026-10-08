#!/usr/bin/env ruby
# frozen_string_literal: true

require "rubocop"

QUERY_METHODS = %i[
  find
  find_by
  find_by!
  where
  exists?
].freeze

MESSAGE = "DriveItemをテナントスコープなしで直接検索しています"

def drive_item_chain?(node)
  return false unless node

  if node.const_type?
    return node.const_name == "DriveItem"
  end

  return false unless node.send_type?

  drive_item_chain?(node.receiver)
end

path = ARGV.first

unless path
  warn "Usage: bundle exec ruby script/lint_tenant_input.rb FILE"
  exit 2
end

unless File.file?(path)
  warn "File not found: #{path}"
  exit 2
end

source = File.read(path)

processed_source = RuboCop::AST::ProcessedSource.new(
  source,
  RUBY_VERSION.to_f,
  path
)

processed_source.diagnostics.each do |diagnostic|
  warn diagnostic.render
end

ast = processed_source.ast

unless ast
  warn "ASTを生成できませんでした: #{path}"
  exit 2
end

# ASTを走査して、DriveItemを直接検索している箇所を検出する
# 違反を検出したnodeを格納しておく場所
violations = []

ast.each_node(:send) do |node|
  next unless QUERY_METHODS.include?(node.method_name)
  next unless drive_item_chain?(node.receiver)

  # DriveItemを直接検索している箇所を検出した場合、violationsに追加する
  violations << node
end

# violationsが空の場合は、正常終了する
if violations.empty?
  puts "#{path}: no violations"
  exit 0
end

# 検出場所の情報を出力する
violations.each do |node|
  location = node.location.expression

  puts "#{path}:#{location.line}:#{location.column + 1}: #{MESSAGE}"
  puts "  #{node.source}"
end

warn "#{violations.length} violation(s) detected"
exit 1