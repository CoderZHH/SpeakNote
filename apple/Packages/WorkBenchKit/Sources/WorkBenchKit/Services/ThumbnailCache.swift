import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoded thumbnail data has a byte budget as well as an entry limit.
struct ThumbnailMemoryBudget {
  let limit: Int
  private(set) var bytes = 0
  private var values: [String: Data] = [:]
  private var order: [String] = []
  init(limit: Int = 16 * 1024 * 1024) { self.limit = max(0, limit) }
  mutating func value(for key: String) -> Data? {
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value
  }
  mutating func insert(_ value: Data, for key: String) {
    if let old = values.removeValue(forKey: key) { bytes -= old.count }
    order.removeAll { $0 == key }
    guard value.count <= limit else { return }
    while bytes + value.count > limit || order.count >= 128 {
      guard !order.isEmpty else { break }
      let oldest = order.removeFirst()
      if let data = values.removeValue(forKey: oldest) { bytes -= data.count }
    }
    values[key] = value
    order.append(key)
    bytes += value.count
  }
}

actor ThumbnailCache {
  static let shared = ThumbnailCache()
  private var values = ThumbnailMemoryBudget()
  func image(url: URL, hash: String, pixels: Int) throws -> Data {
    let pixels = min(1600, max(1, pixels))
    let key = hash + "-" + String(pixels)
    if let value = values.value(for: key) { return value }
    let result: Data = try autoreleasepool {
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let cg = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw WorkBenchError("图片尚未下载") }
      let data = NSMutableData()
      guard
        let output = CGImageDestinationCreateWithData(
          data, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw WorkBenchError("无法生成缩略图") }
      CGImageDestinationAddImage(
        output, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
      try require(CGImageDestinationFinalize(output), "缩略图生成失败")
      let result = data as Data
      return result
    }
    values.insert(result, for: key)
    return result
  }
}
