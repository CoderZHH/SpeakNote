import SwiftUI

struct TreeMoveMenu: View {
  let item: WorkspaceItem
  @Environment(AppSession.self) private var session
  private var snapshot: WorkspaceSnapshot { session.workspace?.snapshot ?? .init() }
  private var siblingTargets: [WorkspaceItem] {
    switch item.entity {
    case .collections:
      return snapshot[.collections].filter {
        $0.id != item.id && $0.status != "done" && $0[.spaceID] == item[.spaceID]
      }
    case .projects:
      return snapshot[.projects].filter { $0.id != item.id && $0.status != "done" }
    case .learning:
      return snapshot[.learning].filter { $0.id != item.id && $0.status != "done" }
    case .lessons:
      if !item[.collectionID].isNull {
        let current = snapshot.item(.collections, item[.collectionID].string)
        let spaceID = current?[.spaceID] ?? .null
        return snapshot[.collections].filter {
          $0.status != "done" && $0[.spaceID] == spaceID
        }
      }
      return snapshot[.learning].filter { $0.status != "done" }
    default:
      return []
    }
  }

  var body: some View {
    if !siblingTargets.isEmpty {
      Menu("移动与排序", systemImage: "arrow.up.arrow.down") {
        if [.projects, .collections, .learning].contains(item.entity) {
          let ordered = siblingTargets
          if let first = ordered.first {
            Button("移到最前", systemImage: "arrow.up.to.line") {
              move(target: first, placement: .before)
            }
          }
          if let last = ordered.last {
            Button("移到最后", systemImage: "arrow.down.to.line") {
              move(target: last, placement: .after)
            }
          }
        }
        if [.learning, .collections, .lessons].contains(item.entity) {
          Divider()
          ForEach(siblingTargets) { destination in
            Button(
              item.entity == .lessons
                ? "移入「\(destination.title)」" : "作为「\(destination.title)」子项"
            ) {
              move(target: destination, placement: .inside)
            }
          }
          if [.learning, .collections].contains(item.entity), !item[.parentID].isNull,
            let root = siblingTargets.first(where: { $0[.parentID].isNull })
          {
            Button("移回顶层") { move(target: root, placement: .after) }
          }
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
