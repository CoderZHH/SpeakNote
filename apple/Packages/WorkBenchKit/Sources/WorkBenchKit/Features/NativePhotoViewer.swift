#if os(iOS)
  import SwiftUI
  import UIKit
  import ImageIO

  struct NativePhotoViewer: UIViewControllerRepresentable {
    let urls: [URL]
    let initialIndex: Int
    let close: () -> Void
    func makeUIViewController(context: Context) -> PhotoPreviewController {
      PhotoPreviewController(urls: urls, index: initialIndex, close: close)
    }
    func updateUIViewController(_ controller: PhotoPreviewController, context: Context) {}
  }

  final class PhotoPreviewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate, UIGestureRecognizerDelegate
  {
    let urls: [URL]
    var index: Int
    let close: () -> Void
    let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    let counter = UILabel()
    var dragging = false
    private var finishing = false
    init(urls: [URL], index: Int, close: @escaping () -> Void) {
      self.urls = urls
      self.index = max(0, min(index, urls.count - 1))
      self.close = close
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .black
      view.accessibilityIdentifier = "photo.preview"
      addChild(pages)
      view.addSubview(pages.view)
      pages.didMove(toParent: self)
      pages.dataSource = self
      pages.delegate = self
      if !urls.isEmpty {
        pages.setViewControllers([page(index)], direction: .forward, animated: false)
      }
      let done = UIButton(type: .system)
      done.setImage(UIImage(systemName: "xmark"), for: .normal)
      done.tintColor = .white
      done.backgroundColor = UIColor.darkGray.withAlphaComponent(0.7)
      done.layer.cornerRadius = 22
      done.accessibilityLabel = "关闭照片"
      done.accessibilityIdentifier = "photo.preview.close"
      done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
      done.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(done)
      counter.textColor = .white
      counter.font = .preferredFont(forTextStyle: .subheadline)
      counter.textAlignment = .center
      counter.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(counter)
      updateCounter()
      NSLayoutConstraint.activate([
        done.trailingAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        done.widthAnchor.constraint(equalToConstant: 44),
        done.heightAnchor.constraint(equalToConstant: 44),
        counter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        counter.bottomAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      ])
      let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
      pan.delegate = self
      view.addGestureRecognizer(pan)
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      if !dragging { pages.view.frame = view.bounds }
    }
    private func page(_ i: Int) -> PhotoZoomPage { PhotoZoomPage(url: urls[i], index: i) }
    func pageViewController(_ p: UIPageViewController, viewControllerBefore v: UIViewController)
      -> UIViewController?
    {
      guard let item = v as? PhotoZoomPage, item.index > 0 else { return nil }
      return page(item.index - 1)
    }
    func pageViewController(_ p: UIPageViewController, viewControllerAfter v: UIViewController)
      -> UIViewController?
    {
      guard let item = v as? PhotoZoomPage, item.index + 1 < urls.count else { return nil }
      return page(item.index + 1)
    }
    func pageViewController(
      _ p: UIPageViewController, didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
      if completed, let item = p.viewControllers?.first as? PhotoZoomPage {
        index = item.index
        updateCounter()
      }
    }
    private func updateCounter() {
      counter.text = urls.count > 1 ? "\(index + 1) / \(urls.count)" : ""
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer,
        let page = pages.viewControllers?.first as? PhotoZoomPage,
        page.scroll.zoomScale <= page.scroll.minimumZoomScale + 0.01
      else { return false }
      let velocity = pan.velocity(in: view)
      return velocity.y > 0 && velocity.y > abs(velocity.x)
    }
    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
      let dy = max(0, pan.translation(in: view).y)
      if pan.state == .began || pan.state == .changed {
        dragging = true
        pages.view.transform = CGAffineTransform(translationX: 0, y: dy)
        view.backgroundColor = UIColor.black.withAlphaComponent(
          max(0.15, 1 - dy / view.bounds.height))
        counter.alpha = max(0, 1 - dy / 120)
      } else if pan.state == .ended && (dy > 100 || pan.velocity(in: view).y > 900) {
        finish()
      } else if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
        UIView.animate(
          withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, delay: 0,
          options: .curveEaseOut
        ) {
          self.pages.view.transform = .identity
          self.view.backgroundColor = .black
          self.counter.alpha = 1
        } completion: { _ in
          self.dragging = false
        }
      }
    }
    override func accessibilityPerformEscape() -> Bool {
      finish()
      return true
    }
    private func finish() {
      guard !finishing else { return }
      finishing = true
      UIView.animate(
        withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18, delay: 0,
        options: .curveEaseOut
      ) {
        self.pages.view.alpha = 0
        self.view.backgroundColor = .clear
        self.counter.alpha = 0
      } completion: { _ in
        self.close()
      }
    }
  }

  final class PhotoZoomPage: UIViewController, UIScrollViewDelegate {
    let url: URL
    let index: Int
    let scroll = UIScrollView()
    let image = UIImageView()
    private var load: Task<Void, Never>?
    private var size = CGSize.zero
    init(url: URL, index: Int) {
      self.url = url
      self.index = index
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { load?.cancel() }
    override func viewDidLoad() {
      super.viewDidLoad()
      scroll.delegate = self
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 5
      scroll.showsVerticalScrollIndicator = false
      scroll.showsHorizontalScrollIndicator = false
      scroll.bounces = false
      scroll.bouncesZoom = true
      view.addSubview(scroll)
      scroll.addSubview(image)
      image.contentMode = .scaleAspectFit
      image.isAccessibilityElement = true
      image.accessibilityIdentifier = "photo.preview.image"
      image.accessibilityLabel = "订单截图"
      image.accessibilityHint = "双击放大或还原，原尺寸下向下滑动关闭"
      let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
      tap.numberOfTapsRequired = 2
      scroll.addGestureRecognizer(tap)
      let url = url
      load = Task { [weak self] in
        let cg = await Task.detached(priority: .userInitiated) {
          autoreleasepool { () -> CGImage? in
            guard
              let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(
              source, 0,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
          }
        }.value
        guard !Task.isCancelled, let self else { return }
        if let cg {
          self.image.image = UIImage(cgImage: cg)
          self.size = .zero
          self.view.setNeedsLayout()
        } else {
          let error = UILabel(frame: self.view.bounds)
          error.text = "图片暂时无法读取"
          error.textColor = .white
          error.textAlignment = .center
          error.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          self.view.addSubview(error)
        }
      }
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      scroll.frame = view.bounds
      guard size != view.bounds.size, view.bounds.width > 0 else { return }
      size = view.bounds.size
      scroll.zoomScale = 1
      guard let original = image.image?.size else { return }
      let factor = min(size.width / original.width, size.height / original.height)
      image.frame = CGRect(
        origin: .zero,
        size: CGSize(width: original.width * factor, height: original.height * factor))
      scroll.contentSize = image.bounds.size
      center()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    private func center() {
      image.accessibilityValue = "缩放 \(Int(scroll.zoomScale * 100))%"
      image.center = CGPoint(
        x: max(scroll.bounds.width, scroll.contentSize.width) / 2,
        y: max(scroll.bounds.height, scroll.contentSize.height) / 2)
    }
    @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
      if scroll.zoomScale > 1.01 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let p = tap.location(in: image)
        let width = scroll.bounds.width / 2.5
        let height = scroll.bounds.height / 2.5
        scroll.zoom(
          to: CGRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height),
          animated: true)
      }
    }
  }
#endif
