import XCTest

final class WorkBenchUITests: XCTestCase {
  @MainActor func launch() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "io.github.coderzhh.workbenchpreview.ios")
    app.launchEnvironment["WORKBENCH_QA"] = "1"
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    return app
  }
  @MainActor func testPrimaryTabsDoNotRepeatLargeTitles() {
    let app = launch()
    for title in ["思考", "项目", "今日"] {
      app.tabBars.buttons[title].tap()
      if title == "思考" {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "思考-紧凑工具栏"
        image.lifetime = .keepAlways
        add(image)
      }
      XCTAssertFalse(app.navigationBars.staticTexts[title].exists, "Tab 已提供页面名称，顶部不应重复大标题")
    }
    app.tabBars.buttons["拍照"].tap()
    XCTAssertTrue(app.buttons["添加订单"].waitForExistence(timeout: 5))
  }
  @MainActor func testPhoneListsHaveNoSelectionOrEmptyHeaderAndSettingsStayReachable() {
    let app = launch()
    func capture(_ name: String) {
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)
    }
    func checkRoot(_ prompt: String) {
      let search = app.textFields[prompt]
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      XCTAssertLessThan(search.frame.minY, 115, "内容应紧接安全区域，不保留空导航栏")
      XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
      XCTAssertEqual(app.cells.matching(NSPredicate(format: "selected == true")).count, 0)
    }
    app.tabBars.buttons["拍照"].tap()
    checkRoot("搜索品牌或拍摄要求")
    XCTAssertFalse(app.buttons["共享空间"].exists)
    capture("手机拍照-无默认选中与空栏")
    app.buttons["添加订单"].tap()
    let name = "导航验证 " + String(UUID().uuidString.prefix(5))
    app.textFields["order.brand.input"].tap()
    app.textFields["order.brand.input"].typeText(name)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["photo.field.brand"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable, "进入详情必须恢复返回")
    app.buttons["photo.field.brand"].tap()
    XCTAssertTrue(app.buttons["完成修改"].isHittable)
    app.buttons["取消"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    checkRoot("搜索品牌或拍摄要求")

    app.tabBars.buttons["思考"].tap()
    checkRoot("搜索思考")
    app.buttons["thought.new"].tap()
    let editor = app.textViews["thought.content"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(name + "思考\n正文")
    XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
    app.buttons["keyboard.done"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    checkRoot("搜索思考")
    capture("手机思考-无默认选中与空栏")

    app.tabBars.buttons["项目"].tap()
    checkRoot("搜索")
    capture("手机项目-顶部紧凑")
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["设置"].firstMatch.tap()
    XCTAssertTrue(app.buttons["settings.sync"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["settings.photoSharing"].isHittable)
    XCTAssertFalse(app.staticTexts["高级选项"].exists)
    capture("手机设置-同步共享与备份分组")
    app.buttons["settings.photoSharing"].tap()
    XCTAssertTrue(app.navigationBars["拍照共享"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
    capture("手机设置-拍照共享")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.buttons["settings.sync"].waitForExistence(timeout: 5))
  }
  @MainActor func testAssistantSharingMovesToSettingsWithoutLosingDetailReturn() {
    let app = XCUIApplication(bundleIdentifier: "io.github.coderzhh.workbenchpreview.photo")
    app.launchEnvironment["WORKBENCH_QA"] = "1"
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    app.tabBars.buttons["订单"].tap()
    XCTAssertTrue(app.textFields["搜索品牌或拍摄要求"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
    XCTAssertFalse(app.buttons["共享空间"].exists)
    XCTAssertEqual(app.cells.matching(NSPredicate(format: "selected == true")).count, 0)
    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(app.buttons["settings.photoSharing"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["导出工作区"].exists, "助手不能获得个人工作区能力")
    app.buttons["settings.photoSharing"].tap()
    XCTAssertTrue(app.navigationBars["拍照共享"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["拍摄"].tap()
    XCTAssertTrue(app.textFields["搜索品牌或拍摄要求"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars.firstMatch.isHittable)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "拍照助手-拍摄列表紧凑导航"
    shot.lifetime = .keepAlways
    add(shot)
    app.terminate()
  }
  @MainActor func testThoughtContinuousAutosaveAndNavigationDoneInDarkMode() async throws {
    let app = XCUIApplication(bundleIdentifier: "io.github.coderzhh.workbenchpreview.ios")
    app.launchEnvironment["WORKBENCH_QA"] = "1"
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-AppleInterfaceStyle", "Dark"]
    app.launch()
    app.tabBars.buttons["思考"].tap()
    app.buttons["thought.new"].tap()
    let editor = app.textViews["thought.content"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    let title = "连续编辑 " + String(UUID().uuidString.prefix(5))
    editor.typeText(title + "\n")
    try await Task.sleep(for: .seconds(1))
    for text in ["一边还在经历一个时刻\n", "一边就已经知道未来会有多怀念此刻了\n", "继续编辑与自动保存"] {
      editor.typeText(text)
      try await Task.sleep(for: .seconds(1))
      XCTAssertFalse(app.otherElements["thought.save.error"].exists)
      XCTAssertFalse(app.buttons["核对版本"].exists)
    }
    let done = app.buttons["keyboard.done"]
    XCTAssertTrue(done.isHittable)
    XCTAssertLessThan(done.frame.maxY, app.frame.height * 0.18, "完成应固定在顶部导航栏")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "思考-深色连续编辑与顶部完成"
    shot.lifetime = .keepAlways
    add(shot)
    let content = editor.value as? String
    done.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, content)
    XCTAssertFalse(app.otherElements["thought.save.error"].exists)
  }
  // Opt-in: host seeds one synthetic conflict in the dedicated QA simulator.
  @MainActor func testAssistantReviewsConflictDirectlyFromOrder() throws {
    guard ProcessInfo.processInfo.environment["PHOTO_CONFLICT_FIXTURE"] == "1" else {
      throw XCTSkip("Requires the isolated photo-conflict fixture")
    }
    let app = XCUIApplication(bundleIdentifier: "io.github.coderzhh.workbenchpreview.photo")
    app.launchEnvironment["WORKBENCH_QA"] = "1"
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    app.tabBars.buttons["订单"].tap()
    let search = app.textFields["搜索品牌或拍摄要求"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("核对修改 QA")
    let row = app.staticTexts["核对修改 QA"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    let review = app.buttons["photo.reviewChanges"]
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    review.tap()
    XCTAssertTrue(app.buttons["使用共享版本"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本机拍摄要求")).firstMatch.exists)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "共享拍摄要求")).firstMatch.exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "拍照助手-订单直接核对字段差异"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["使用共享版本"].tap()
    XCTAssertTrue(app.staticTexts["已核对完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()
    XCTAssertFalse(review.exists)
    let requirements = app.buttons["photo.field.requirements"]
    XCTAssertTrue(requirements.label.contains("共享拍摄要求"))
    XCTAssertTrue(app.buttons["photo.field.notes"].label.contains("本机备注已保留"))
    app.terminate()
  }
  @MainActor func testNewSemesterOwnsCoursesAndCardActionsStayDirect() {
    let app = launch()
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["课程"].firstMatch.tap()
    app.buttons["课程管理"].tap()
    app.buttons["学期管理"].firstMatch.tap()
    app.buttons["新建学期"].tap()
    let term = "新学期 " + String(UUID().uuidString.prefix(5))
    let title = app.textFields["学期名称"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap(); title.press(forDuration: 1.1)
    if app.menuItems["全选"].exists { app.menuItems["全选"].tap() }
    title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + term)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", term)).firstMatch.waitForExistence(timeout: 5))
    app.buttons["完成"].tap()
    app.buttons["课程管理"].tap()
    app.buttons["添加课程"].tap()
    let course = "学期关联课程 " + String(UUID().uuidString.prefix(5))
    let field = app.textFields["课程名称"].exists ? app.textFields["课程名称"] : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(course)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons[course].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["添加上课安排"].firstMatch.exists)
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.menu.")).firstMatch.tap()
    XCTAssertTrue(app.buttons["编辑课程信息"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["添加上课安排"].exists)
    XCTAssertFalse(app.buttons["标记完结"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "课程-课程操作菜单"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["添加上课安排"].firstMatch.tap()
    XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 5))
    app.buttons["保存"].tap()
    app.buttons["filter.课表"].tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", course))
      .firstMatch.waitForExistence(timeout: 5))
    app.buttons["filter.课程"].tap()
    let meeting = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "course.meeting.")
    ).firstMatch
    XCTAssertTrue(meeting.waitForExistence(timeout: 5))
    meeting.tap()
    XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()

    let add = app.buttons["添加到" + course]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    let id = String(add.identifier.dropFirst("collection.task.add.".count))
    let input = app.descendants(matching: .any)
      .matching(identifier: "collection.task.input." + id).firstMatch
    XCTAssertTrue(input.exists)
    XCTAssertFalse(app.buttons["item.attachments." + id].exists)
    input.tap()
    input.typeText("阅读第一章")
    add.tap()
    let task = app.buttons["阅读第一章"]
    XCTAssertTrue(task.waitForExistence(timeout: 5))
    let taskID = String(task.identifier.dropFirst("item.title.".count))
    app.buttons["item.remarks." + taskID].tap()
    let remarkID = "item.remark.text." + taskID
    app.buttons[remarkID].tap()
    let remark = app.textViews[remarkID]
    XCTAssertTrue(remark.waitForExistence(timeout: 5))
    remark.typeText("这一条备注\n第二行")
    let done = app.buttons["item.remark.done"]
    XCTAssertTrue(done.isHittable)
    let shotWithDone = XCTAttachment(screenshot: app.screenshot())
    shotWithDone.name = "课程待办-备注旁完成"
    shotWithDone.lifetime = .keepAlways
    self.add(shotWithDone)
    done.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons[remarkID].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons[remarkID].label.contains("第二行"))
    app.buttons["item.attachments." + taskID].tap()
    XCTAssertTrue(app.buttons["选择文件"].waitForExistence(timeout: 5))
  }
  @MainActor func testCalendarMonthPinchHasBoundsAndRevealsPreviews() {
    let app = launch()
    app.tabBars.buttons["更多"].tap(); app.staticTexts["日历"].firstMatch.tap()
    let grid = app.descendants(matching: .any).matching(identifier: "calendar.month.grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    grid.pinch(withScale: 2, velocity: 1)
    XCTAssertNotEqual(grid.value as? String, "缩放 100%")
    grid.pinch(withScale: 0.25, velocity: -1)
    XCTAssertEqual(grid.value as? String, "缩放 100%")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "日历-缩放后复位"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["filter.周"].tap()
    let timeline = app.descendants(matching: .any).matching(identifier: "calendar.week.timeline").firstMatch
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    timeline.pinch(withScale: 1.5, velocity: 1)
    XCTAssertNotEqual(timeline.value as? String, "每小时 56 点")
  }
  @MainActor func testCollectionActionsOpenInOneTap() {
    let app = launch()
    app.tabBars.buttons["项目"].tap()
    app.buttons["新建"].tap()
    let name = "直接操作 " + String(UUID().uuidString.prefix(5))
    let input = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(name)
    app.buttons["添加"].tap()
    app.buttons[name].firstMatch.tap()
    let actions = app.buttons["collection.actions"]
    XCTAssertTrue(actions.waitForExistence(timeout: 5))
    actions.tap()
    XCTAssertTrue(app.buttons["添加随手记"].waitForExistence(timeout: 3), "一次点击应直接出现操作")
    XCTAssertTrue(app.buttons["标记完结"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "集合详情-单层操作"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["添加随手记"].tap()
    XCTAssertTrue(app.buttons["entry.association"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["entry.association"].label.contains(name))
    app.buttons["取消"].tap()
  }
  @MainActor func testPhotoGalleryAndPinnedActionInBothClients() {
    for bundle in ["io.github.coderzhh.workbenchpreview.ios", "io.github.coderzhh.workbenchpreview.photo"] {
      let app = XCUIApplication(bundleIdentifier: bundle)
      app.launchEnvironment["WORKBENCH_QA"] = "1"
      app.launch()
      app.tabBars.buttons[bundle.hasSuffix(".photo") ? "订单" : "拍照"].tap()
      let order = app.staticTexts["原生测试订单 1"]
      XCTAssertTrue(order.waitForExistence(timeout: 5))
      order.tap()
      let gallery = app.scrollViews["photo.gallery"]
      XCTAssertTrue(gallery.waitForExistence(timeout: 5))
      XCTAssertGreaterThan(gallery.frame.width, app.frame.width * 0.85)
      XCTAssertGreaterThan(gallery.frame.height, 299)
      XCTAssertTrue(app.buttons["photo.stage"].isHittable)
      XCTAssertTrue(app.buttons["photo.field.deadline"].isHittable)
      XCTAssertTrue(app.buttons["photo.advance"].isHittable)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = bundle.hasSuffix(".photo") ? "拍照助手-紧凑订单详情" : "WorkBench-紧凑订单详情"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      gallery.buttons["查看订单截图原图"].firstMatch.tap()
      let close = app.buttons["photo.preview.close"]
      XCTAssertTrue(close.waitForExistence(timeout: 5))
      let image = app.images["photo.preview.image"]
      XCTAssertTrue(image.waitForExistence(timeout: 5))
      image.doubleTap()
      let zoomed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "缩放 250%"), object: image)
      XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
      let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
      center.press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
      XCTAssertTrue(close.exists, "放大后下滑应移动图片，不能关闭")
      image.doubleTap()
      let unzoomed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "缩放 100%"), object: image)
      XCTAssertEqual(XCTWaiter.wait(for: [unzoomed], timeout: 3), .completed)
      center.press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
      XCTAssertTrue(close.waitForNonExistence(timeout: 5), "原图下滑应返回订单详情")
      XCTAssertTrue(app.buttons["photo.stage"].isHittable)
      gallery.swipeLeft()
      XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
      app.scrollViews["photo.detail.content"].swipeUp()
      XCTAssertTrue(app.buttons["photo.advance"].isHittable, "滚动后推进操作仍应可见")
      XCTAssertTrue(app.buttons["photo.stage"].isHittable, "滚动后品牌和进度仍应可见")
      app.navigationBars.buttons.element(boundBy: 0).tap()
      XCTAssertTrue(order.waitForExistence(timeout: 5))
      app.terminate()
    }
  }
  @MainActor func testPhotoInlineCancelAndReturn() {
    let app = launch()
    app.tabBars.buttons["拍照"].tap()
    let order = app.staticTexts["原生测试订单 1"]
    XCTAssertTrue(order.waitForExistence(timeout: 5))
    order.tap()
    let brand = app.buttons["photo.field.brand"]
    XCTAssertTrue(brand.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["更多信息"].exists)
    XCTAssertTrue(app.buttons["photo.stage"].exists)
    XCTAssertTrue(app.buttons["photo.field.deadline"].exists)
    XCTAssertTrue(app.buttons["photo.advance"].isHittable)
    XCTAssertTrue(app.buttons["photo.field.postage"].exists)
    XCTAssertTrue(app.buttons["photo.field.commission"].exists)
    XCTAssertEqual(app.buttons.matching(identifier: "photo.field.notes").count, 1)
    let detail = XCTAttachment(screenshot: app.screenshot())
    detail.name = "拍照详情-信息层级"
    detail.lifetime = .keepAlways
    add(detail)
    let deadline = app.buttons["photo.field.deadline"]
    let originalDeadline = deadline.label
    deadline.tap()
    XCTAssertTrue(app.datePickers["order.date.picker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["完成修改"].isHittable)
    app.buttons["取消"].tap()
    XCTAssertEqual(app.buttons["photo.field.deadline"].label, originalDeadline)
    brand.tap()
    let input = app.descendants(matching: .any).matching(identifier: "photo.edit.brand").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(" 临时修改")
    XCTAssertTrue(app.buttons["完成修改"].isHittable, "键盘出现时确认必须可用")
    app.buttons["取消"].tap()
    XCTAssertTrue(app.buttons["photo.field.brand"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["原生测试订单 1"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["原生测试订单 1 临时修改"].exists)
  }
  @MainActor func testBrandOnlyNewOrderSavesAndCancellationCreatesNothing() {
    let app = launch()
    app.tabBars.buttons["拍照"].tap()
    app.buttons["添加订单"].tap()
    let name = "只填品牌 UI " + String(UUID().uuidString.prefix(5))
    let brand = app.textFields["order.brand.input"]
    XCTAssertTrue(brand.waitForExistence(timeout: 5))
    brand.tap()
    brand.typeText(name)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["photo.field.brand"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["photo.field.brand"].label.contains(name))
    XCTAssertFalse(app.navigationBars.staticTexts[name].exists, "订单名称只在正文显示一次")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["添加订单"].tap()
    app.textFields["order.brand.input"].tap()
    app.textFields["order.brand.input"].typeText("取消，不建单")
    app.buttons["取消"].tap()
    XCTAssertFalse(app.staticTexts["取消，不建单"].exists)
  }
  @MainActor func testNewOrderDeadlineUsesOptionalNativeDatePicker() {
    let app = launch()
    app.tabBars.buttons["拍照"].tap()
    let addOrder = app.buttons["添加订单"]
    XCTAssertTrue(addOrder.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(addOrder.frame.midY, app.frame.height * 0.65)
    addOrder.tap()
    XCTAssertFalse(app.datePickers["order.date.picker"].exists)
    let deadline = app.switches["截止日期"].firstMatch
    XCTAssertTrue(deadline.waitForExistence(timeout: 5))
    deadline.switches.firstMatch.tap()
    let selector = app.buttons["order.date.picker"]
    XCTAssertTrue(selector.waitForExistence(timeout: 5))
    selector.tap()
    XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5))
    app.buttons["完成"].tap()
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "新建订单-原生可选日期"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    deadline.switches.firstMatch.tap()
    XCTAssertFalse(app.datePickers["order.date.picker"].exists)
    app.buttons["取消"].tap()
  }
  @MainActor func testOverflowRetainsLearningAndCourseEntrances() {
    let app = launch()
    let more =
      app.tabBars.buttons["更多"].exists ? app.tabBars.buttons["更多"] : app.tabBars.buttons["More"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.tap()
    app.staticTexts["学习"].firstMatch.tap()
    XCTAssertTrue(app.buttons["新建"].waitForExistence(timeout: 5))
    app.navigationBars.buttons["更多"].tap()
    app.staticTexts["课程"].firstMatch.tap()
    XCTAssertTrue(app.buttons["课程管理"].waitForExistence(timeout: 5))
  }
  @MainActor func testThoughtCreatesInFullEditorAndCustomTagsRemainEditable() {
    let app = launch()
    app.tabBars.buttons["思考"].tap()
    let create = app.buttons["thought.new"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    create.tap()
    let editor = app.textViews["thought.content"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["保存"].exists, "新思考直接在正文自动保存")
    let name = "标签流程 " + String(UUID().uuidString.prefix(6))
    editor.tap()
    editor.typeText(name + "\n这里是正文，不要变成小弹窗。")
    app.buttons["thought.tags"].tap()
    let input = app.textFields["thought.tag.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    let tag = "自定义" + String(UUID().uuidString.prefix(3))
    input.typeText(tag)
    app.buttons["thought.tag.add"].tap()
    XCTAssertTrue(app.buttons["移除标签 " + tag].waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "思考-直接编辑与自定义标签"
    shot.lifetime = .keepAlways
    add(shot)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    XCTAssertTrue(app.buttons["移除标签 " + tag].waitForExistence(timeout: 5))
    XCTAssertTrue((app.textViews["thought.content"].value as? String)?.contains(name) == true)
    app.buttons["移除标签 " + tag].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    row.tap()
    XCTAssertFalse(app.buttons["移除标签 " + tag].exists)
    XCTAssertTrue(app.buttons["thought.tags"].exists)
  }
  @MainActor func testTodayExpandsProjectsAndLearningWithLinkedTaskCreation() {
    let app = launch()
    let suffix = String(UUID().uuidString.prefix(5))
    for section in ["项目", "学习"] {
      app.tabBars.buttons["今日"].tap()
      app.buttons["filter.记录"].tap()
      app.buttons["filter." + section].tap()
      app.buttons["添加" + section].tap()
      let title = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
      XCTAssertTrue(title.waitForExistence(timeout: 5))
      let collection = section + "今日展开 " + suffix
      title.tap()
      title.typeText(collection)
      app.buttons["添加"].tap()
      let header = app.buttons[collection].firstMatch
      for _ in 0..<25 {
        if header.exists && header.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(header.waitForExistence(timeout: 5))
      let add = app.buttons["添加到" + collection]
      for _ in 0..<5 {
        if add.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(add.isHittable, "今日卡片必须直接显示添加待办入口")
      let id = add.identifier.replacingOccurrences(
        of: "collection.task.add.", with: "collection.task.input.")
      let input = app.descendants(matching: .any).matching(identifier: id).firstMatch
      input.tap()
      let task = "卡片待办 " + section + suffix
      input.typeText(task)
      add.tap()
      XCTAssertTrue(app.buttons[task].waitForExistence(timeout: 5))
      header.tap()
      XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons[task].exists, "详情与今日卡片应显示同一条关联任务")
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "今日-学习展开与原地添加"
    shot.lifetime = .keepAlways
    add(shot)
  }
  @MainActor func testMobileEditingHasDoneAndAttachmentPickerSavesImage() {
    let app = launch()
    app.tabBars.buttons["项目"].tap()
    app.buttons["新建"].tap()
    let entry = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    let name = "键盘附件 " + String(UUID().uuidString.prefix(5))
    entry.tap()
    entry.typeText(name)
    app.buttons["添加"].tap()
    let header = app.buttons[name].firstMatch
    for _ in 0..<25 {
      if header.exists && header.isHittable { break }
      app.swipeUp()
    }
    header.tap()
    XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
    let add = app.buttons.matching(NSPredicate(format: "label == %@", "添加到" + name))
      .allElementsBoundByIndex.first { $0.isHittable }!
    let fieldID = add.identifier.replacingOccurrences(
      of: "collection.task.add.", with: "collection.task.input.")
    let field = app.descendants(matching: .any).matching(identifier: fieldID).firstMatch
    field.tap()
    field.typeText("验证收起键盘")
    XCTAssertTrue(app.buttons["keyboard.done"].waitForExistence(timeout: 5))
    app.buttons["keyboard.done"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    add.tap()
    let note = app.buttons["添加备注…"].firstMatch
    note.tap()
    let input = app.textViews.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "item.remark.text.")
    ).firstMatch
    input.typeText("备注不会丢")
    XCTAssertTrue(app.buttons["item.remark.done"].waitForExistence(timeout: 5))
    app.buttons["item.remark.done"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    let media = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "item.attachments.")
    ).firstMatch
    media.tap()
    app.buttons["照片图库"].tap()
    let photo = app.images.matching(NSPredicate(format: "label CONTAINS %@", "照片")).firstMatch
    if !photo.waitForExistence(timeout: 5) { print(app.debugDescription) }
    XCTAssertTrue(photo.exists)
    let pickerShot = XCTAttachment(screenshot: app.screenshot())
    pickerShot.name = "附件-系统相册选择"
    pickerShot.lifetime = .keepAlways
    self.add(pickerShot)
    let point = photo.frame
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.midX, dy: point.midY))
      .tap()
    let addPhoto = app.buttons["Add"]
    XCTAssertTrue(addPhoto.waitForExistence(timeout: 5))
    XCTAssertTrue(addPhoto.isEnabled)
    addPhoto.tap()
    let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查看附件 "))
      .firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    header.tap()
    XCTAssertTrue(preview.waitForExistence(timeout: 5), "重新进入后附件必须保留")
  }
  @MainActor func testThoughtKeyboardDoneRetainsText() {
    let app = launch()
    app.tabBars.buttons["思考"].tap()
    app.buttons["thought.new"].tap()
    let input = app.textViews["thought.content"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    let content = "完成按钮测试 " + String(UUID().uuidString.prefix(5)) + "\n第二行正文"
    input.typeText(content)
    XCTAssertTrue(app.buttons["keyboard.done"].waitForExistence(timeout: 5))
    app.buttons["keyboard.done"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, content)
  }
  @MainActor func testCourseDetailGroupsScheduleAndTasks() {
    let app = launch()
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["课程"].firstMatch.tap()
    if app.buttons["载入示例课表"].exists { app.buttons["载入示例课表"].tap() }
    app.buttons["filter.课程"].tap()
    let title = app.buttons["示例课程 F"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["上课安排"].exists)
    XCTAssertTrue(app.buttons["添加到示例课程 F"].isHittable)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "课程详情-信息分组"
    shot.lifetime = .keepAlways
    add(shot)
    app.swipeUp()
    XCTAssertFalse(app.staticTexts["备注与附件"].exists)
  }
  @MainActor func testCourseWeekScrollKeepsTimeAxisAndOpensDetails() throws {
    let app = launch()
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["课程"].firstMatch.tap()
    let install = app.buttons["载入示例课表"]
    if install.exists { install.tap() }
    let grid = app.descendants(matching: .any).matching(identifier: "calendar.week.timeline").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    let hour = grid.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2}")).firstMatch
    XCTAssertTrue(hour.exists)
    let axisX = hour.frame.minX
    let course = try XCTUnwrap(grid.buttons.allElementsBoundByIndex.first { $0.isHittable })
    let start = XCTAttachment(screenshot: app.screenshot())
    start.name = "iPhone 周课表"
    start.lifetime = .keepAlways
    add(start)

    let monday = grid.staticTexts["周一"]
    let mondayX = monday.frame.minX
    grid.swipeLeft()
    XCTAssertTrue(!monday.exists || monday.frame.minX < mondayX)
    XCTAssertEqual(hour.frame.minX, axisX, accuracy: 1)
    let scrolled = XCTAttachment(screenshot: app.screenshot())
    scrolled.name = "iPhone 周课表横向滚动"
    scrolled.lifetime = .keepAlways
    add(scrolled)

    grid.swipeRight()
    XCTAssertTrue(course.isHittable)
    course.tap()
    XCTAssertTrue(app.staticTexts["上课安排"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["课程备注"].exists)
  }
  @MainActor func testCourseRemarksUseNativeEditor() {
    let app = launch()
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["课程"].firstMatch.tap()
    let install = app.buttons["载入示例课表"]
    if install.exists { install.tap() }
    app.buttons["课程管理"].tap()
    app.buttons["添加课程"].tap()
    let name = "Course remarks " + String(UUID().uuidString.prefix(5))
    let nameField = app.textFields["课程名称"].exists ? app.textFields["课程名称"] : app.textViews.firstMatch
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText(name)
    app.buttons["保存"].tap()
    let course = app.buttons[name]
    XCTAssertTrue(course.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["课程备注"].exists)
    let courseID = String(app.buttons["添加到" + name].identifier.dropFirst("collection.task.add.".count))
    course.tap()
    XCTAssertTrue(app.staticTexts["课程备注"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["粘贴图片"].exists)
    let identifier = "item.remark.text." + courseID
    let remark = app.buttons[identifier]
    remark.tap()
    let input = app.textViews[identifier]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    input.typeText("Lecture notes\nSecond line")
    app.buttons["item.remark.done"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertTrue(remark.waitForExistence(timeout: 5))
    XCTAssertTrue(remark.label.contains("Second line"))
    app.navigationBars.buttons.firstMatch.tap()
    course.tap()
    XCTAssertTrue(remark.waitForExistence(timeout: 5))
    XCTAssertTrue(remark.label.contains("Second line"))
  }
  @MainActor func testNewTaskExposesAssociationImportanceAndScheduleBeforeCreation() {
    let app = launch()
    let suffix = String(UUID().uuidString.prefix(6))
    let project = "DailyChange 关联项目 " + suffix
    app.tabBars.buttons["项目"].tap()
    app.buttons["新建"].tap()
    let input = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(project)
    app.buttons["添加"].tap()
    app.tabBars.buttons["今日"].tap()
    app.buttons["添加任务"].firstMatch.tap()
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    let name = "新建属性 " + suffix
    input.tap()
    input.typeText(name)
    XCTAssertTrue(app.buttons["entry.attachments"].exists)
    app.buttons["重要程度 5，共五级"].tap()
    app.buttons["entry.association"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText(project)
    app.buttons[project].firstMatch.tap()
    XCTAssertTrue(app.buttons["entry.association"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["entry.association"].label.contains(project))
    app.buttons["entry.schedule"].tap()
    XCTAssertTrue(app.switches["schedule.timed"].waitForExistence(timeout: 5))
    app.switches["schedule.timed"].switches.firstMatch.tap()
    let start = app.datePickers["schedule.start"].value as? String
    app.buttons["完成"].tap()
    app.buttons["entry.schedule"].tap()
    XCTAssertEqual(app.switches["schedule.timed"].value as? String, "1")
    XCTAssertEqual(app.datePickers["schedule.start"].value as? String, start)
    app.buttons["schedule.cancel"].tap()
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "新建任务-可选属性"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["添加"].tap()
    let row = app.buttons[name].firstMatch
    for _ in 0..<20 {
      if row.exists && row.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    let association = app.buttons[
      row.identifier.replacingOccurrences(of: "item.title.", with: "item.association.")]
    XCTAssertTrue(association.exists)
    XCTAssertTrue(association.label.contains(project))
    XCTAssertGreaterThan(association.frame.width, 150, "关联名称应在标题下方获得足够宽度")
    let screenshotRow = XCTAttachment(screenshot: app.screenshot())
    screenshotRow.name = "手机任务-完整关联标签与底部添加"
    screenshotRow.lifetime = .keepAlways
    add(screenshotRow)
    association.tap()
    XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).isHittable)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let actions = row.identifier.replacingOccurrences(of: "item.title.", with: "item.actions.")
    app.buttons[actions].tap()
    let level = app.buttons["重要程度 5，共五级"]
    XCTAssertTrue(level.isSelected)
    app.buttons["安排时间"].tap()
    XCTAssertEqual(app.switches["schedule.timed"].value as? String, "1")
    XCTAssertEqual(app.datePickers["schedule.start"].value as? String, start)
    app.buttons["schedule.cancel"].tap()
  }
  @MainActor func testTaskImportancePalettePersistsEveryLevelAndTitleOpensWithText() {
    let app = launch()
    app.tabBars.buttons["项目"].tap()
    app.buttons["新建"].tap()
    let suffix = String(UUID().uuidString.prefix(5))
    let project = "色彩检查 " + suffix
    let entry = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    entry.typeText(project)
    app.buttons["添加"].tap()
    let projectButton = app.buttons[project].firstMatch
    for _ in 0..<15 {
      if projectButton.exists && projectButton.isHittable { break }
      app.swipeUp()
    }
    projectButton.tap()
    let field = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "collection.task.input.")
    ).firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    let name = "重要程度完整回归 " + suffix
    field.tap()
    field.typeText(name)
    app.buttons["添加到" + project].tap()
    let title = app.buttons[name].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    let titleID = title.identifier
    let actionsID = titleID.replacingOccurrences(of: "item.title.", with: "item.actions.")
    let actions = app.buttons[actionsID]
    for level in [3, 5, 2, 4, 1] {
      actions.tap()
      let choices = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "重要程度 "))
      XCTAssertEqual(choices.count, 5)
      for index in 0..<choices.count { XCTAssertTrue(choices.element(boundBy: index).isHittable) }
      app.buttons["重要程度 \(level)，共五级"].tap()
      let saved = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "重要程度 \(level)，共五级"), object: actions)
      XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
      actions.tap()
      XCTAssertTrue(app.buttons["重要程度 \(level)，共五级"].isSelected)
      if level == 5 {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "重要程度-五色可见与选中"
        shot.lifetime = .keepAlways
        add(shot)
      }
      app.buttons["安排时间"].tap()
      XCTAssertTrue(app.buttons["schedule.cancel"].waitForExistence(timeout: 5))
      app.buttons["schedule.cancel"].tap()
    }
    app.buttons[titleID].tap()
    let input =
      app.textFields[titleID].waitForExistence(timeout: 3)
      ? app.textFields[titleID] : app.textViews[titleID]
    XCTAssertTrue(input.exists)
    XCTAssertEqual(input.value as? String, name, "点标题编辑时应保留原文字")
    app.terminate()
  }
  @MainActor func testScheduleReminderRequiresSpecificTimeAndRestoresSchedule() {
    let app = launch()
    app.tabBars.buttons["今日"].tap()
    app.buttons["添加任务"].firstMatch.tap()
    let input = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    let name = "提醒安排 " + String(UUID().uuidString.prefix(5))
    input.tap()
    input.typeText(name)
    app.buttons["添加"].tap()
    let title = app.buttons[name].firstMatch
    for _ in 0..<12 {
      if title.exists && title.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    let actionsID = title.identifier.replacingOccurrences(of: "item.title.", with: "item.actions.")
    app.buttons[actionsID].tap()
    app.buttons["安排时间"].tap()
    let reminder = app.switches["schedule.reminder"]
    XCTAssertTrue(reminder.waitForExistence(timeout: 5))
    XCTAssertFalse(reminder.isEnabled)
    app.switches["schedule.timed"].switches.firstMatch.tap()
    XCTAssertTrue(reminder.isEnabled)
    reminder.switches.firstMatch.tap()
    XCTAssertEqual(reminder.value as? String, "1")
    app.switches["schedule.timed"].switches.firstMatch.tap()
    XCTAssertFalse(reminder.isEnabled)
    XCTAssertEqual(reminder.value as? String, "0")
    app.switches["schedule.timed"].switches.firstMatch.tap()
    let from = app.datePickers["schedule.start"].value as? String
    let until = app.datePickers["schedule.end"].value as? String
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "安排时间-提醒开关"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["完成"].tap()
    app.buttons[actionsID].tap()
    app.buttons["安排时间"].tap()
    XCTAssertTrue(app.switches["schedule.timed"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.switches["schedule.timed"].value as? String, "1")
    XCTAssertEqual(app.datePickers["schedule.start"].value as? String, from)
    XCTAssertEqual(app.datePickers["schedule.end"].value as? String, until)
    app.buttons["取消"].tap()
  }
  @MainActor func testFocusContinuesInSystemSurfaceAndPausesAndEnds() async throws {
    let app = launch()
    app.tabBars.buttons["今日"].tap()
    for _ in 0..<10 {
      if !app.buttons["focus.end"].exists { break }
      app.buttons["focus.end"].tap()
    }
    let start = app.buttons["focus.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()
    let toggle = app.buttons["focus.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "暂停")
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暂时无法显示实时活动")).firstMatch
        .exists)
    XCUIDevice.shared.press(.home)
    let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertTrue(system.wait(for: .runningForeground, timeout: 5))
    // Observe a real timer tick after the Home transition and widget launch.
    try await Task.sleep(for: .seconds(2))
    system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.055)).press(forDuration: 1)
    let activityTitle = system.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "自由专注")
    ).firstMatch
    XCTAssertTrue(activityTitle.waitForExistence(timeout: 5), "真实灵动岛展开后应显示当前专注")
    let screenshot = XCTAttachment(screenshot: system.screenshot())
    screenshot.name = "专注-系统实时活动"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    activityTitle.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    XCTAssertTrue(app.tabBars.buttons["今日"].isSelected)
    app.buttons["focus.toggle"].tap()
    XCTAssertTrue(
      app.buttons.matching(identifier: "focus.toggle").matching(
        NSPredicate(format: "label == %@", "继续")
      ).firstMatch.waitForExistence(timeout: 5))
    let pausedText = app.staticTexts["focus.elapsed"].label
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(app.staticTexts["focus.elapsed"].label, pausedText, "暂停后的系统时间必须固定")
    app.buttons["focus.toggle"].tap()
    XCTAssertTrue(
      app.buttons.matching(identifier: "focus.toggle").matching(
        NSPredicate(format: "label == %@", "暂停")
      ).firstMatch.waitForExistence(timeout: 5))
    app.buttons["focus.end"].tap()
    XCTAssertTrue(app.buttons["focus.start"].waitForExistence(timeout: 5))
  }
  @MainActor func testMonthCalendarFillsWidthAndSelectionUpdatesAgenda() {
    let app = launch()
    app.tabBars.buttons["更多"].tap()
    app.staticTexts["日历"].firstMatch.tap()
    let grid = app.descendants(matching: .any).matching(identifier: "calendar.month.grid")
      .firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    XCTAssertFalse(app.datePickers.firstMatch.exists, "月历不应使用小型系统日期选择器")
    let days = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day."))
    XCTAssertGreaterThanOrEqual(days.count, 28)
    let first = days.element(boundBy: 0)
    let seventh = days.element(boundBy: 6)
    XCTAssertGreaterThan(seventh.frame.maxX - first.frame.minX, app.frame.width * 0.85)
    let month = app.staticTexts["calendar.month.heading"].label
    app.buttons["calendar.next"].tap()
    XCTAssertNotEqual(app.staticTexts["calendar.month.heading"].label, month)
    app.buttons["calendar.previous"].tap()
    XCTAssertEqual(app.staticTexts["calendar.month.heading"].label, month)
    let date = days.element(boundBy: 10)
    let label = date.label
    date.tap()
    XCTAssertTrue(date.isSelected)
    XCTAssertTrue(app.staticTexts["calendar.agenda.heading"].exists)
    XCTAssertFalse(label.isEmpty)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "完整月历与当日日程"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
  @MainActor func testCourseDetailKeepsScheduleAndQuickTaskTogether() {
    let app = launch()
    let more =
      app.tabBars.buttons["更多"].exists ? app.tabBars.buttons["更多"] : app.tabBars.buttons["More"]
    more.tap()
    let learning = app.staticTexts["学习"].firstMatch
    let calendar = app.staticTexts["日历"].firstMatch
    let courses = app.staticTexts["课程"].firstMatch
    XCTAssertLessThan(learning.frame.minY, calendar.frame.minY)
    XCTAssertLessThan(calendar.frame.minY, courses.frame.minY)
    courses.tap()
    if app.buttons["载入示例课表"].exists { app.buttons["载入示例课表"].tap() }
    app.buttons["课程"].firstMatch.tap()
    let course = app.buttons["示例课程 A"].firstMatch
    XCTAssertTrue(course.waitForExistence(timeout: 5))
    course.tap()
    XCTAssertTrue(app.staticTexts["13:00–16:40"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.navigationBars.count, 1, "详情只能有一层返回工具栏")
    XCTAssertTrue(app.staticTexts["示例教室 1"].exists)
    XCTAssertTrue(app.staticTexts["第 9–16 周"].exists)
    XCTAssertTrue(app.buttons["collection.task.add.course-2026-research-methods"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "课程-安排与待办"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
  @MainActor func testCollectionQuickAddKeepsAssociationAndExpandsItems() {
    let app = launch()
    for module in ["项目", "学习"] {
      if module == "项目" {
        app.tabBars.buttons[module].tap()
      } else {
        let more =
          app.tabBars.buttons["更多"].exists ? app.tabBars.buttons["更多"] : app.tabBars.buttons["More"]
        more.tap()
        app.staticTexts[module].firstMatch.tap()
      }
      app.buttons["新建"].tap()
      let name = module + "直接添加 " + String(UUID().uuidString.prefix(5))
      let entry = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 5))
      entry.tap()
      entry.typeText(name)
      app.buttons["添加"].tap()
      let add = app.buttons["添加到" + name]
      XCTAssertTrue(add.waitForExistence(timeout: 5))
      let inputID = add.identifier.replacingOccurrences(
        of: "collection.task.add.", with: "collection.task.input.")
      let input = app.descendants(matching: .any).matching(identifier: inputID).firstMatch
      XCTAssertTrue(input.waitForExistence(timeout: 5), "每个集合有独立输入框")
      XCTAssertFalse(add.isEnabled)
      input.tap()
      let task = "直接添加待办 " + String(UUID().uuidString.prefix(5))
      let outlineID = add.identifier.replacingOccurrences(
        of: "collection.task.add.", with: "collection.task.field.")
      let outline = app.descendants(matching: .any).matching(identifier: outlineID).firstMatch
      XCTAssertEqual(outline.frame.height, add.frame.height, accuracy: 1)
      XCTAssertEqual(outline.frame.minY, add.frame.minY, accuracy: 1)
      input.typeText(task + "\n补充第一行\n补充第二行")
      XCTAssertEqual(outline.frame.height, add.frame.height, accuracy: 1, "换行后仍须等高")
      XCTAssertEqual(outline.frame.minY, add.frame.minY, accuracy: 1)
      add.tap()
      let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", task)).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 5), "新待办应留在对应集合卡片中")
      XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "添加成功后收起键盘，恢复浏览和导航")
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = module + "-卡片直接添加"
      attachment.lifetime = .keepAlways
      self.add(attachment)
    }
  }
  @MainActor func testTodayFiltersShareCompactRecordNavigation() {
    let app = launch()
    app.tabBars.buttons["今日"].tap()
    XCTAssertTrue(app.buttons["任务"].exists)
    app.buttons["记录"].tap()
    for title in ["随手记", "思考", "学习", "项目"] {
      XCTAssertTrue(app.scrollViews.buttons[title].firstMatch.exists)
    }
    app.buttons["任务"].tap()
    for title in ["今日", "以后", "已完成", "放弃"] {
      XCTAssertTrue(
        app.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
          .firstMatch.exists)
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists, "查看条目时不能自动进入编辑")
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "今日-紧凑任务布局"
    image.lifetime = .keepAlways
    add(image)
  }
  @MainActor func testNewTaskKeepsActionsVisibleAndCancelDoesNotCreate() {
    let app = launch()
    app.tabBars.buttons["今日"].tap()
    app.buttons["添加任务"].firstMatch.tap()
    let input = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    let name = "取消的新任务 " + String(UUID().uuidString.prefix(6))
    input.tap()
    input.typeText(name + "，这是一段会自动换行的长内容，用来检查输入时仍能看到完整内容和操作按钮。")
    XCTAssertTrue(app.buttons["添加"].isHittable)
    XCTAssertTrue(app.buttons["取消"].isHittable)
    app.buttons["取消"].tap()
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists)
    app.buttons["添加任务"].firstMatch.tap()
    let emptyInput = app.descendants(matching: .any).matching(identifier: "entry.title").firstMatch
    XCTAssertTrue(emptyInput.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["添加"].isEnabled)
    app.buttons["取消"].tap()
  }
  @MainActor func testAssistantHasNoPersonalModules() {
    let app = XCUIApplication(bundleIdentifier: "io.github.coderzhh.workbenchpreview.photo")
    app.launchEnvironment["WORKBENCH_QA"] = "1"
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["订单"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.tabBars.buttons["拍摄"].exists)
    XCTAssertFalse(app.buttons["更多模块"].exists)
    XCTAssertFalse(app.tabBars.buttons["今日"].exists)
  }
}
