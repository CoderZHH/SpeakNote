import SwiftUI

struct TreeMoveMenu: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  var body: some View {
    Menu("移动到", systemImage: "folder") {
      ForEach(
        (session.workspace?.snapshot[.learning] ?? []).filter {
          $0.id != item.id && $0.status != "done"
        }
      ) { destination in
        Button(destination.title) { move(target: destination, placement: .inside) }
      }
      if let root = session.workspace?.snapshot[.learning].first(where: {
        $0[.parentID].isNull && $0.id != item.id
      }) {
        if item.entity == .learning && !item[.parentID].isNull {
          Button("移到顶层") { move(target: root, placement: .after) }
        }
      }
    }
  }
  func move(target: WorkspaceItem, placement: MovePlacement) {
    session.run {
      _ = try await session.workspace?.perform(
        .move(
          item.entity, id: item.id, targetEntity: target.entity, targetID: target.id,
          placement: placement))
    }
  }
}
func treeDepth(_ item: WorkspaceItem, rows: [WorkspaceItem]) -> Int {
  var parent = item[.parentID].string
  var seen: Set<String> = [item.id]
  var depth = 0
  while !parent.isEmpty, seen.insert(parent).inserted,
    let ancestor = rows.first(where: { $0.id == parent })
  {
    depth += 1
    parent = ancestor[.parentID].string
  }
  return min(depth, 8)
}
func treeOrder(_ rows: [WorkspaceItem]) -> [WorkspaceItem] {
  var result: [WorkspaceItem] = []
  var seen = Set<String>()
  func append(_ row: WorkspaceItem) {
    guard seen.insert(row.id).inserted else { return }
    result.append(row)
    for child in rows.filter({ $0[.parentID] == .string(row.id) }).sorted(by: {
      $0[.position].int < $1[.position].int
    }) { append(child) }
  }
  for root in rows.filter({ row in
    row[.parentID].isNull || !rows.contains(where: { $0.id == row[.parentID].string })
  }).sorted(by: { $0[.position].int < $1[.position].int }) { append(root) }
  for row in rows { append(row) }
  return result
}
