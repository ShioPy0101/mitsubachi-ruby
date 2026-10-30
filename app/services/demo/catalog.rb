module Demo
  # ストレージ上の実体や通常の DriveItem ID と関連付かない、表示専用のカタログ。
  module Catalog
    ITEMS = [
      { id: "documents", parent: nil, name: "資料", size: nil },
      { id: "projects", parent: nil, name: "プロジェクト", size: nil },
      { id: "guide", parent: nil, name: "はじめに.pdf", size: "1.2 MB" },
      { id: "proposal", parent: "documents", name: "サービス紹介.pdf", size: "2.4 MB" },
      { id: "minutes", parent: "documents", name: "議事録.txt", size: "12 KB" },
      { id: "design", parent: "projects", name: "デザイン案.png", size: "3.1 MB" },
      { id: "schedule", parent: "projects", name: "スケジュール.xlsx", size: "84 KB" }
    ].map(&:freeze).freeze
  end
end
