import Foundation

public struct MetricInput: Sendable {
  public var videoID: String
  public var title: String
  public var url: String
  public var publishedAt: String
  public var capturedAt: Date?
  public var plays: Int64?
  public var likes: Int64?
  public var comments: Int64?
  public var shares: Int64?
  public var followers: Int64?
  public init(
    videoID: String, title: String, url: String = "", publishedAt: String = "",
    capturedAt: Date? = nil, plays: Int64? = nil, likes: Int64? = nil, comments: Int64? = nil,
    shares: Int64? = nil, followers: Int64? = nil
  ) {
    self.videoID = videoID
    self.title = title
    self.url = url
    self.publishedAt = publishedAt
    self.capturedAt = capturedAt
    self.plays = plays
    self.likes = likes
    self.comments = comments
    self.shares = shares
    self.followers = followers
  }
}
extension WorkspaceEngine {
  func importMetrics(accountID: String, rows: [MetricInput], now: Date) throws -> CommandResult {
    _ = try exists(.accounts, accountID)
    try require((1...1000).contains(rows.count), "一次请导入 1–1000 条作品记录")
    for row in rows {
      let id = try Validation.text(.string(row.videoID), "作品 ID", max: 300, required: true)
      let title = try Validation.text(.string(row.title), "作品标题", max: 500, required: true)
      let url = try Validation.text(.string(row.url), "作品链接", max: 2000).string
      try require(
        url.isEmpty || (URL(string: url)?.scheme == "https" && URL(string: url)?.host != nil),
        "作品链接需要是 HTTPS 地址")
      let captured = Clock.stamp(row.capturedAt ?? now)
      var args: [JSONValue] = [
        .id(), .string(accountID), id, title, .string(url),
        try Validation.text(.string(row.publishedAt), "发布时间", max: 100),
      ]
      for number in [row.plays, row.likes, row.comments, row.shares, row.followers] {
        args.append(
          try number.map { try Validation.integer(.integer($0), 0...9_007_199_254_740_991) }
            ?? .null)
      }
      args.append(.string(captured))
      try db.execute(
        "INSERT INTO metrics(id,account_id,video_id,title,url,published_at,plays,likes,comments,shares,followers,captured_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(account_id,video_id,captured_at) DO UPDATE SET title=excluded.title,url=excluded.url,published_at=excluded.published_at,plays=excluded.plays,likes=excluded.likes,comments=excluded.comments,shares=excluded.shares,followers=excluded.followers",
        args)
    }
    return CommandResult(id: accountID)
  }
}
