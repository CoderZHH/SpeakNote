import Foundation
import Testing

@testable import WorkBenchKit

@Test func customLayoutsRejectUnboundedProposals() {
  for value: CGFloat? in [nil, .infinity, -.infinity, .nan, 0, -1, .greatestFiniteMagnitude, 430] {
    let width = finiteLayoutWidth(value, fallback: 800)
    #expect(width.isFinite && width > 0 && width <= 100_000)
  }
  #expect(finiteLayoutWidth(430, fallback: 800) == 430)
  #expect(finiteLayoutHeight(.infinity, fallback: 40) == 40)
  #expect(finiteLayoutHeight(.nan, fallback: 40) == 40)
  #expect(finiteLayoutHeight(.greatestFiniteMagnitude, fallback: 40) == 100_000)
}
@Test func thumbnailCacheRemainsWithinByteBudgetAndEvictsLeastRecent() {
  var cache = ThumbnailMemoryBudget(limit: 100)
  cache.insert(Data(repeating: 1, count: 40), for: "a")
  cache.insert(Data(repeating: 2, count: 40), for: "b")
  #expect(cache.value(for: "a") != nil)
  cache.insert(Data(repeating: 3, count: 40), for: "c")
  #expect(cache.value(for: "b") == nil && cache.value(for: "a") != nil)
  for i in 0..<10_000 {
    cache.insert(Data(repeating: 1, count: 70), for: String(i))
    #expect(cache.bytes <= 100)
  }
  cache.insert(Data(repeating: 1, count: 101), for: "oversized")
  #expect(cache.value(for: "oversized") == nil && cache.bytes <= 100)
}
