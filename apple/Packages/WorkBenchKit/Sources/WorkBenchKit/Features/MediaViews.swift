import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct AttachmentThumbnail: View {
  let attachment: MediaAttachment
  let directory: URL
  var pixels = 240
  var contentMode: ContentMode = .fill
  @State private var data: Data?
  var body: some View {
    Group {
      if let data {
        #if os(macOS)
          if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
          }
        #else
          if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
          }
        #endif
      } else {
        Rectangle().fill(.quaternary).overlay {
          Image(systemName: attachment.mime.hasPrefix("video") ? "play.rectangle" : "photo")
            .foregroundStyle(.secondary)
        }
      }
    }
    .task(id: attachment.hash + String(pixels)) {
      data = try? await ThumbnailCache.shared.image(
        url: directory.appendingPathComponent(attachment.fileKey), hash: attachment.hash,
        pixels: pixels)
    }
  }
}
struct PhotoGallery: View {
  let attachments: [MediaAttachment]
  let directory: URL
  var height: CGFloat = WorkbenchDesign.PhotoLayout.imageHeight
  @State private var preview: URL?
  @State private var selected: String?
  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(attachments) { attachment in
          Button {
            preview = directory.appendingPathComponent(attachment.fileKey)
          } label: {
            AttachmentThumbnail(
              attachment: attachment, directory: directory, pixels: 1200,
              contentMode: .fit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchDesign.fieldBackground)
            .containerRelativeFrame(.horizontal)
            .frame(height: height).clipped()
          }.buttonStyle(.plain).accessibilityLabel("查看订单截图原图")
            .id(attachment.id)
        }
      }.scrollTargetLayout()
    }.scrollTargetBehavior(.paging).scrollPosition(id: $selected)
      .scrollIndicators(.hidden).clipShape(.rect(cornerRadius: WorkbenchDesign.radius))
      .overlay(alignment: .bottomTrailing) {
        if attachments.count > 1 {
          let index = attachments.firstIndex { $0.id == selected } ?? 0
          Text("\(index + 1) / \(attachments.count)").font(.caption.monospacedDigit())
            .foregroundStyle(.white).padding(.horizontal, WorkbenchDesign.Space.small)
            .padding(.vertical, 4).background(.black.opacity(0.55), in: .capsule)
            .padding(WorkbenchDesign.Space.small).allowsHitTesting(false)
        }
      }
      .accessibilityIdentifier("photo.gallery")
      .onChange(of: attachments.map(\.id)) { _, ids in
        if !ids.contains(selected ?? "") { selected = ids.first }
      }
      #if os(iOS)
        .fullScreenCover(
          isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })
        ) {
          let urls = attachments.map { directory.appendingPathComponent($0.fileKey) }
          NativePhotoViewer(
            urls: urls, initialIndex: urls.firstIndex(of: preview ?? URL(fileURLWithPath: "/")) ?? 0
          ) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { preview = nil }
          }.ignoresSafeArea().presentationBackground(.clear)
        }
      #else
        .quickLookPreview($preview)
      #endif
  }
}
struct MediaPicker: View {
  let title: String
  let imagesOnly: Bool
  var importing: Binding<Bool>? = nil
  let onData: @MainActor (Data, String) async throws -> Void
  @Environment(AppSession.self) private var session
  @State private var selections: [PhotosPickerItem] = []
  @State private var filePicker = false
  @State private var photosPicker = false
  @State private var loading = false
  var body: some View {
    Menu {
      Button("照片图库", systemImage: "photo.on.rectangle") { photosPicker = true }
      Button("选择文件", systemImage: "folder") { filePicker = true }
    } label: {
      Label(loading ? "正在导入" : title, systemImage: loading ? "hourglass" : "plus")
    }
    .buttonStyle(.borderless).menuStyle(.borderlessButton).menuIndicator(.hidden)
    .disabled(loading)
    .photosPicker(
      isPresented: $photosPicker, selection: $selections, maxSelectionCount: 10,
      matching: imagesOnly ? .images : .any(of: [.images, .videos])
    )
    .onChange(of: loading) { _, value in importing?.wrappedValue = value }
    .onChange(of: selections) { _, values in
      guard !values.isEmpty else { return }
      loading = true
      Task {
        defer {
          loading = false
          selections = []
        }
        do {
          for value in values {
            guard let data = try await value.loadTransferable(type: Data.self) else {
              throw WorkBenchError("无法读取所选媒体")
            }
            let types = value.supportedContentTypes
            let movie = types.contains { $0.conforms(to: .movie) }
            let ext =
              types.compactMap(\.preferredFilenameExtension).first ?? (movie ? "mov" : "jpg")
            try await onData(data, "附件." + ext)
          }
        } catch { session.error = error.localizedDescription }
      }
    }
    .fileImporter(
      isPresented: $filePicker, allowedContentTypes: imagesOnly ? [.image] : [.image, .movie],
      allowsMultipleSelection: true
    ) { result in
      if case .failure(let error) = result, (error as NSError).code == NSUserCancelledError {
        return
      }
      loading = true
      session.run {
        defer { loading = false }
        for url in try result.get() {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let maximum = imagesOnly ? 20 * 1024 * 1024 : 100 * 1024 * 1024
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          try require(size > 0 && size <= maximum, "附件超过允许大小")
          let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }
            .value
          try await onData(data, url.lastPathComponent)
        }
      }
    }
  }
}
