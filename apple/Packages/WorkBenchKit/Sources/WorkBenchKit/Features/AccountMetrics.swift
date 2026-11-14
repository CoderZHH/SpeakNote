import Charts
import SwiftUI
import UniformTypeIdentifiers

struct AccountMetricsView: View {
  let account: WorkspaceItem
  @Environment(AppSession.self) private var session
  @State private var importing = false
  @State private var sort = "plays"
  @State private var range = 0
  var metrics: [WorkspaceItem] {
    session.workspace?.snapshot[.metrics].filter { $0.fields.text("account_id") == account.id }
      .sorted { $0.fields.text("captured_at") < $1.fields.text("captured_at") } ?? []
  }
  var latest: [WorkspaceItem] {
    var rows: [String: WorkspaceItem] = [:]
    for row in metrics { rows[row.fields.text("video_id")] = row }
    return rows.values.sorted { $0.fields.integer(sort) > $1.fields.integer(sort) }
  }
  var history: [(String, Int64)] {
    var current: [String: WorkspaceItem] = [:]
    var result: [(String, Int64)] = []
    for time in Set(metrics.map { $0.fields.text("captured_at") }).sorted() {
      for row in metrics where row.fields.text("captured_at") == time {
        current[row.fields.text("video_id")] = row
      }
      let values = current.values.filter { !$0.fields[value: "plays"].isNull }
      if !values.isEmpty {
        result.append((time, values.reduce(0) { $0 + $1.fields.integer("plays") }))
      }
    }
    return result.filter {
      range == 0
        || ((try? Clock.parse($0.0)) ?? .distantPast)
          >= Date().addingTimeInterval(-Double(range) * 86400)
    }
  }
  var body: some View {
    WorkspaceList {
      Section {
        HStack {
          ForEach(
            [("plays", "播放"), ("likes", "点赞"), ("comments", "评论"), ("shares", "分享")], id: \.0
          ) { key, label in
            VStack(alignment: .leading, spacing: 5) {
              Text(label).font(.caption).foregroundStyle(.secondary)
              let values = latest.filter { !$0.fields[value: key].isNull }
              Text(
                values.isEmpty
                  ? "—" : values.reduce(Int64(0)) { $0 + $1.fields.integer(key) }.formatted()
              ).font(.headline.monospacedDigit())
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        Picker("时间范围", selection: $range) {
          Text("7 天").tag(7)
          Text("30 天").tag(30)
          Text("全部").tag(0)
        }.pickerStyle(.segmented).labelsHidden()
        if !history.isEmpty {
          Chart(history, id: \.0) { point in
            if let time = try? Clock.parse(point.0) {
              LineMark(x: .value("时间", time), y: .value("累计播放", point.1))
              PointMark(x: .value("时间", time), y: .value("累计播放", point.1))
            }
          }.frame(height: 180)
        }
      }
      Section("作品表现") {
        Picker("排序", selection: $sort) {
          Text("播放").tag("plays")
          Text("点赞").tag("likes")
          Text("评论").tag("comments")
        }
        ForEach(latest) { row in
          VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: row.fields.text("url")), url.scheme == "https" {
              Link(row.title, destination: url).font(.headline)
            } else {
              Text(row.title).font(.headline)
            }
            HStack {
              metricLabel(row, "plays", "播放")
              metricLabel(row, "likes", "赞")
              metricLabel(row, "comments", "评论")
              metricLabel(row, "shares", "分享")
            }.font(.caption).foregroundStyle(.secondary)
          }.padding(.vertical, 5)
        }
      }
    }.navigationTitle(account.fields.text("name"))
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("导入数据", systemImage: "square.and.arrow.down") { importing = true }
        }
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        session.run {
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let value = try await Task.detached { try JSONValue(data: Data(contentsOf: url)) }.value
          let rows = value["rows"].isNull ? value.array : value["rows"].array
          let input = try rows.map { row -> MetricInput in
            func number(_ field: String) throws -> Int64? {
              let value = row[field]
              if value.isNull || value == .string("") { return nil }
              return try Validation.integer(value, 0...9_007_199_254_740_991).int
            }
            return try MetricInput(
              videoID: row["video_id"].string, title: row["title"].string, url: row["url"].string,
              publishedAt: row["published_at"].string,
              capturedAt: row["captured_at"].isNull ? nil : Clock.parse(row["captured_at"].string),
              plays: number("plays"), likes: number("likes"), comments: number("comments"),
              shares: number("shares"), followers: number("followers"))
          }
          _ = try await session.workspace?.perform(
            .importMetrics(accountID: account.id, rows: input))
        }
      }
  }
  func metricLabel(_ row: WorkspaceItem, _ field: String, _ label: String) -> some View {
    Text(
      (row.fields[value: field].isNull ? "—" : row.fields.integer(field).formatted()) + " " + label
    ).frame(maxWidth: .infinity, alignment: .leading)
  }
}
