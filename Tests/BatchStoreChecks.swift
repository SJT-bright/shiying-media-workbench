import Foundation

// BatchStore 的测试宿主源码（任务 B）。只在 build/batch-B 的独立可执行件里编译，
// 不进 App 目标（Scripts/build.sh 只编 Sources/*.swift）。
// 数据根/worker/tools 三个注入点都指向 build/batch-B 自己的目录，绝不碰正式数据或固定 /tmp 根。
// 入口在 build/batch-B/main.swift（top-level 代码只能放 main.swift），本文件只提供 BatchStoreChecks。
// 类名带 BatchStore 前缀，避免与 Tests/BatchCoreChecks.swift 里的类型相撞。

@MainActor
final class BatchStoreChecks {
    var failures = 0
    let bundleDir: URL
    let mock: URL
    let tools: URL
    let stubTools: URL

    init() {
        let base = ProcessInfo.processInfo.environment["BATCH_TEST_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/build/batch-B"
        bundleDir = URL(fileURLWithPath: base)
        mock = bundleDir.appendingPathComponent("mock_worker.py")
        let realTools = ProcessInfo.processInfo.environment["SHIYING_TOOLS_DIR"] ?? ""
        tools = URL(fileURLWithPath: realTools)
        stubTools = bundleDir.appendingPathComponent("tools_stub")
        FileManager.default.changeCurrentDirectoryPath(bundleDir.path)
        setenv("SHIYING_TOOLS_DIR", realTools, 1)
    }

    // MARK: - 断言与小工具

    func check(_ name: String, _ ok: Bool, _ extra: String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (extra.isEmpty ? "" : "  [\(extra)]"))
        if !ok { failures += 1 }
    }

    func wait(_ seconds: TimeInterval = 12, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func files(_ dir: URL, suffix: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(suffix) } ?? []
    }

    func freshRoot(_ name: String) -> URL {
        let url = bundleDir.appendingPathComponent("root-" + name)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeStore(root: URL, tools: URL? = nil) -> BatchStore {
        BatchStore.dataRootOverride = root
        BatchStore.workerOverrideURL = mock
        BatchStore.toolsDirectoryOverride = tools ?? self.tools
        let store = BatchStore()
        let parent = root.appendingPathComponent("资料")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store.parentFolder = parent.path
        return store
    }

    func addCollection(_ store: BatchStore, _ name: String) -> URL {
        store.newCollectionName = name
        store.createCollection()
        return URL(fileURLWithPath: store.selectedCollection?.path ?? store.parentFolder)
    }

    func link(_ id: String) -> String { "https://www.douyin.com/video/\(id)" }

    func enqueue(_ store: BatchStore, _ text: String) {
        store.inputText = text
        store.enqueue()
    }

    func item(_ store: BatchStore, _ id: String) -> BatchItem? {
        store.items.first { $0.link.hasSuffix(id) }
    }

    func audioStreamCount(_ path: String) -> Int {
        let probe = Process()
        probe.executableURL = tools.appendingPathComponent("ffprobe")
        var arguments = ["-v", "error", "-of", "json", "-select_streams", "a:0",
                         "-show_entries", "stream=codec_type"]
        arguments.append(path)
        probe.arguments = arguments
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return -1 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else { return 0 }
        return streams.filter { ($0["codec_type"] as? String) == "audio" }.count
    }

    // MARK: - 队列边界

    func runQueue() async {
        // 1. 导入去重与无效行统计 + 成功链路（含音轨）
        let root1 = freshRoot("q1")
        let store = makeStore(root: root1)
        let folder = addCollection(store, "主题A")
        check("建主题", store.selectedCollection != nil, store.error ?? "")
        store.quality = .compact
        store.includeAudio = true
        enqueue(store, "看这条 " + link("7300000000000001001") + " 复制分享\n"
                + link("7300000000000001001") + "\n这是一行没有链接的中文备注\n")
        check("入队只留一条", store.items.count == 1, store.notice ?? "")
        check("重复与无效已计数", (store.notice ?? "").contains("重复 1") && (store.notice ?? "").contains("无效行 1"))
        check("入队不自动联网", store.isRunning == false)
        var snapshot = store.items[0]
        check("入队快照画质", snapshot.qualityRaw == "480", snapshot.qualityRaw)
        check("入队快照音轨", snapshot.wantsAudio == true)
        check("原文只存一份", store.imports.count == 1 && snapshot.sourceText.utf8.count <= 4096,
              "imports=\(store.imports.count) importID=\(snapshot.importID == store.imports.first?.id)")
        store.start()
        _ = await wait { store.isRunning == false }
        snapshot = item(store, "1001") ?? snapshot
        check("单条完成", snapshot.status == .completed, snapshot.error ?? snapshot.title)
        check("分享描述已保留", snapshot.description.contains("不是字幕"), snapshot.description)
        check("时长已保留", snapshot.duration > 0, String(snapshot.duration))
        check("视频文件在位", (snapshot.path.map { FileManager.default.fileExists(atPath: $0) }) ?? false)
        check("音轨已发布", (snapshot.audioPath.map { FileManager.default.fileExists(atPath: $0) }) ?? false,
              snapshot.audioError ?? "nil")
        if let audio = snapshot.audioPath, let video = snapshot.path {
            check("音轨同 stem", (audio as NSString).lastPathComponent
                  == URL(fileURLWithPath: video).deletingPathExtension().lastPathComponent + ".m4a",
                  audio)
        }
        check("已持久化到磁盘", FileManager.default.fileExists(
            atPath: root1.appendingPathComponent("batch/batch-library.json").path))
        check("主题目录里有视频", !files(folder, suffix: ".mp4").isEmpty)

        // 2. 单条失败不停整批
        let store2 = makeStore(root: freshRoot("q2"))
        _ = addCollection(store2, "主题B")
        enqueue(store2, link("7300000000000002001") + "\n" + link("7300000000000001002") + "\n")
        store2.start()
        _ = await wait { store2.isRunning == false }
        let failed = item(store2, "2001")
        let succeeded = item(store2, "1002")
        check("失败条目有可见原因", failed?.status == .failed && !(failed?.error ?? "").isEmpty,
              failed?.error ?? "nil")
        check("失败后整批继续", succeeded?.status == .completed, succeeded?.error ?? "nil")
        check("分别计数", store2.failedCount == 1 && store2.completedCount == 1,
              "failed=\(store2.failedCount) completed=\(store2.completedCount)")

        // 3. 暂停不丢 pending，继续跑完
        let store3 = makeStore(root: freshRoot("q3"))
        _ = addCollection(store3, "主题C")
        store3.includeAudio = false
        enqueue(store3, (1...4).map { link("730000000000000100" + String($0)) }.joined(separator: "\n"))
        store3.start()
        store3.pause()
        _ = await wait { store3.isRunning == false }
        let keptPending = store3.pendingCount
        check("暂停保留待处理", keptPending > 0 && keptPending < 4, "pending=\(keptPending)")
        store3.resume()
        _ = await wait { store3.isRunning == false && store3.pendingCount == 0 }
        check("继续后全部结束", store3.pendingCount == 0 && store3.completedCount == 4,
              "completed=\(store3.completedCount)")
        check("未勾选音轨就不产出 m4a", store3.items.allSatisfy { $0.audioPath == nil })

        // 4. 取消当前并暂停，取消后队列仍可再用
        let store4 = makeStore(root: freshRoot("q4"))
        _ = addCollection(store4, "主题D")
        setMode("default")
        enqueue(store4, link("7300000000000004001") + "\n")
        store4.start()
        _ = await wait(6) { item(store4, "4001")?.status == .running }
        store4.cancelCurrent()
        _ = await wait(8) { store4.isRunning == false }
        let cancelled = item(store4, "4001")
        check("取消当前标已取消", cancelled?.status == .cancelled, cancelled?.error ?? "nil")
        check("取消后清 error", cancelled?.error == nil)
        check("取消即暂停", store4.isPaused == true && store4.isRunning == false)
        check("取消不产音轨", cancelled?.audioPath == nil)

        // 5. 同条目重跑：上一轮迟到回调不得串单（token 守卫）
        let retriedID = item(store4, "4001")?.id
        store4.retryFailed()
        check("重试只动失败/取消", store4.items.filter { $0.status == .pending }.count == 1)
        setMode("forceok")
        store4.start()
        _ = await wait(10) { item(store4, "4001")?.status == .completed }
        let rerun = item(store4, "4001")
        check("重跑成功", rerun?.status == .completed, rerun?.error ?? "nil")
        check("重跑用的是新一轮回调", rerun?.title == "第二轮标题", rerun?.title ?? "nil")
        if let entry = retriedID {
            let stale: [String: Any] = ["event": "metadata", "id": "9", "title": "陈旧标题"]
            store4.handle(stale, entry: entry, token: UUID())
            check("错 token 的迟到回调被丢弃", item(store4, "4001")?.title == "第二轮标题",
                  item(store4, "4001")?.title ?? "nil")
            store4.handle(stale, entry: UUID(), token: UUID())
            check("错 entry 的事件被丢弃", item(store4, "4001")?.title == "第二轮标题")
            // 非运行态条目也不接受事件（取消后再来的尾巴事件不能复活它）
            let doneID = item(store4, "1001")?.id ?? item(store4, "4001")?.id
            if let doneID, store4.items.first(where: { $0.id == doneID })?.status != .running {
                store4.handle(["event": "metadata", "id": "9", "title": "非运行态写入"], entry: doneID, token: UUID())
                check("非运行态条目不写事件",
                      item(store4, "4001")?.title == "第二轮标题")
            }
        }
        setMode("default")

        // 6. 同 videoID 复用：不重复下载、不重复提取
        let store6 = makeStore(root: freshRoot("q6"))
        let folder6 = addCollection(store6, "主题F")
        store6.includeAudio = true
        enqueue(store6, link("7300000000000005001") + "\n" + link("7300000000000005002") + "\n")
        store6.start()
        _ = await wait(16) { store6.isRunning == false }
        let first = item(store6, "5001")
        let second = item(store6, "5002")
        check("两条都完成", first?.status == .completed && second?.status == .completed,
              "\(first?.status.title ?? "?")/\(second?.status.title ?? "?")")
        check("第二条复用同一路径", first?.path == second?.path, "\(first?.path ?? "nil") vs \(second?.path ?? "nil")")
        check("复用不记成取消", second?.status == .completed && second?.error == nil)
        check("音轨也复用", first?.audioPath == second?.audioPath && second?.audioPath != nil)
        check("只下载一份视频", files(folder6, suffix: ".mp4").count == 1,
              files(folder6, suffix: ".mp4").joined(separator: ","))

        // 7. 损坏库：只报错，绝不覆盖
        let root7 = freshRoot("q7")
        let store7 = makeStore(root: root7)
        _ = addCollection(store7, "主题G")
        _ = await wait(0.2) { true }
        let library = root7.appendingPathComponent("batch/batch-library.json")
        let garbage = Data("｛不是 json｝".utf8)
        try? garbage.write(to: library)
        let broken = makeStore(root: root7)
        check("损坏库报错", (broken.error ?? "").contains("读取失败"), broken.error ?? "nil")
        check("损坏库禁写：入队被拒", { broken.inputText = link("7300000000000001001"); broken.enqueue();
              return broken.items.isEmpty }())
        check("损坏库禁写：开始被拒", { broken.start(); return broken.isRunning == false }())
        check("损坏原文未被覆盖",
              (try? Data(contentsOf: library)) == garbage,
              "bytes=\((try? Data(contentsOf: library))?.count ?? -1)")

        // 8. 筛选与搜索（接口给 C 用）
        let store8 = makeStore(root: freshRoot("q8"))
        _ = addCollection(store8, "主题H")
        enqueue(store8, link("7300000000000001003") + "\n" + link("7300000000000002001") + "\n")
        store8.start()
        _ = await wait(14) { store8.isRunning == false }
        store8.statusFilter = "已完成"
        check("按状态筛选", store8.selectedItems.count == 1, store8.selectedItems.count.description)
        store8.statusFilter = "失败"
        check("筛选失败", store8.selectedItems.count == 1)
        store8.statusFilter = "全部"
        store8.search = "有音轨"
        check("按标题搜索", store8.selectedItems.count == 1, store8.selectedItems.count.description)
        store8.search = ""
        check("音轨缺失单独计数", store8.audioMissingCount == 0, store8.audioMissingCount.description)
    }

    func setMode(_ mode: String) {
        try? Data(mode.utf8).write(to: bundleDir.appendingPathComponent("mode.txt"))
    }

    // MARK: - 音轨真实提取与保护

    func runAudio() async {
        // A1 有音轨源 → 真 ffmpeg 提取 + ffprobe 验证
        let store = makeStore(root: freshRoot("a1"))
        let folder = addCollection(store, "音轨主题")
        store.includeAudio = true
        enqueue(store, link("7300000000000001007") + "\n")
        store.start()
        _ = await wait(20) { store.isRunning == false }
        let ok = item(store, "1007")
        check("有音轨：已发布 m4a", (ok?.audioPath.map { FileManager.default.fileExists(atPath: $0) }) ?? false,
              ok?.audioError ?? "nil")
        if let audio = ok?.audioPath {
            check("有音轨：ffprobe 确认含音频流", audioStreamCount(audio) == 1, audio)
            check("有音轨：目录里只剩一份 m4a", files(folder, suffix: ".m4a").count == 1,
                  files(folder, suffix: ".m4a").joined(separator: ","))
            check("有音轨：无残留 staging", files(folder, suffix: ".m4a").filter { $0.hasPrefix(".") }.isEmpty)
        }

        // A2 无音轨源 → audioError 可见、视频保留、不发布
        let store2 = makeStore(root: freshRoot("a2"))
        let folder2 = addCollection(store2, "无音轨主题")
        store2.includeAudio = true
        enqueue(store2, link("7300000000000003001") + "\n")
        store2.start()
        _ = await wait(20) { store2.isRunning == false }
        let noAudio = item(store2, "3001")
        check("无音轨：视频仍完成", noAudio?.status == .completed, noAudio?.error ?? "nil")
        check("无音轨：audioError 可见", (noAudio?.audioError ?? "").contains("音轨"),
              noAudio?.audioError ?? "nil")
        check("无音轨：未发布 m4a", noAudio?.audioPath == nil && files(folder2, suffix: ".m4a").isEmpty)
        check("无音轨：视频文件未被删除",
              (noAudio?.path.map { FileManager.default.fileExists(atPath: $0) }) ?? false)
        check("无音轨：不计进音轨成功", store2.audioMissingCount == 1, store2.audioMissingCount.description)

        // A3 转换中途取消 → 保留视频、清自己 staging、可只补音轨
        let stub = stubDirectory(slow: true, withProbe: true)
        let store3 = makeStore(root: freshRoot("a3"), tools: stub)
        let folder3 = addCollection(store3, "取消主题")
        store3.includeAudio = true
        enqueue(store3, link("7300000000000001008") + "\n")
        store3.start()
        let inAudio = await wait(25) { store3.detail.contains("正在导出配套音轨") }
        print("DIAG a3 进入音轨阶段=\(inAudio) detail=\(store3.detail)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        store3.cancelCurrent()
        _ = await wait(12) { store3.isRunning == false }
        let cancelled = item(store3, "1008")
        print("DIAG a3 items=\(store3.items.count) error=\(store3.error ?? "nil") notice=\(store3.notice ?? "nil") detail=\(store3.detail) status=\(cancelled?.status.title ?? "无") audioError=\(cancelled?.audioError ?? "nil")")
        check("取消音轨：视频仍完成", cancelled?.status == .completed, cancelled?.error ?? "nil")
        check("取消音轨：音轨未发布", cancelled != nil && cancelled?.audioPath == nil)
        check("取消音轨：audioError 说明可重试", (cancelled?.audioError ?? "").contains("取消"),
              cancelled?.audioError ?? "nil")
        check("取消音轨：自己的 staging 已清", cancelled != nil
              && files(folder3, suffix: ".m4a").filter { $0.hasPrefix(".shiying-audio") }.isEmpty,
              files(folder3, suffix: ".m4a").joined(separator: ","))

        // A4 只有 stub ffmpeg、没有 ffprobe → 验证失败必须拒绝发布（不把无法验证当通过）
        let noProbe = stubDirectory(slow: false, withProbe: false)
        let store4 = makeStore(root: freshRoot("a4"), tools: noProbe)
        let folder4 = addCollection(store4, "无探针主题")
        store4.includeAudio = true
        enqueue(store4, link("7300000000000001009") + "\n")
        store4.start()
        _ = await wait(20) { store4.isRunning == false }
        let unverified = item(store4, "1009")
        check("缺 ffprobe：不发布音轨", unverified?.audioPath == nil && files(folder4, suffix: ".m4a").isEmpty,
              files(folder4, suffix: ".m4a").joined(separator: ","))
        check("缺 ffprobe：audioError 说明未验证",
              (unverified?.audioError ?? "").contains("无法验证"), unverified?.audioError ?? "nil")
        check("缺 ffprobe：视频保留", (unverified?.status == .completed)
              && (unverified?.path.map { FileManager.default.fileExists(atPath: $0) } ?? false))

        // A5 同 stem 已被占用 → 加序号发布，不覆盖用户已有文件
        let store5 = makeStore(root: freshRoot("a5"))
        _ = addCollection(store5, "冲突主题")
        store5.includeAudio = false
        enqueue(store5, link("7300000000000001010") + "\n")
        store5.start()
        _ = await wait(20) { store5.isRunning == false }
        let videoOnly = item(store5, "1010")
        check("冲突前置：未勾音轨时 audioPath 为空", videoOnly?.audioPath == nil,
              videoOnly?.audioError ?? "nil")
        if let videoPath = videoOnly?.path, let videoEntry = videoOnly?.id {
            let sentinel = URL(fileURLWithPath: videoPath).deletingPathExtension().appendingPathExtension("m4a")
            try? Data("SENTINEL-用户已有文件".utf8).write(to: sentinel)
            store5.exportAudio(videoEntry)
            _ = await wait(25) { item(store5, "1010")?.audioPath != nil }
            let after = item(store5, "1010")
            check("冲突时不覆盖用户已有文件",
                  (try? String(contentsOf: sentinel, encoding: .utf8))?.hasPrefix("SENTINEL") ?? false,
                  after?.audioError ?? "nil")
            check("冲突时加序号发布",
                  (after?.audioPath.map { $0.hasSuffix("-2.m4a") }) ?? false,
                  after?.audioPath ?? "nil")
        }

        // A6 补导出缺失音轨：走同一串行队列，不重新下载视频
        let store6 = makeStore(root: freshRoot("a6"))
        let folder6 = addCollection(store6, "补导出主题")
        store6.includeAudio = false
        enqueue(store6, link("7300000000000001011") + "\n")
        store6.start()
        _ = await wait(20) { store6.isRunning == false }
        let before = item(store6, "1011")?.path
        let mp4CountBefore = files(folder6, suffix: ".mp4").count
        check("补导出前置：未勾音轨无 m4a", item(store6, "1011")?.audioPath == nil)
        store6.exportMissingAudio()
        _ = await wait(20) { (item(store6, "1011")?.audioPath != nil) || store6.audioMissingCount == 0 }
        let after = item(store6, "1011")
        check("补导出成功", (after?.audioPath.map { FileManager.default.fileExists(atPath: $0) }) ?? false,
              after?.audioError ?? "nil")
        check("补导出未重新下载", after?.path == before
              && files(folder6, suffix: ".mp4").count == mp4CountBefore,
              "before=\(mp4CountBefore) after=\(files(folder6, suffix: ".mp4").count)")
        check("补导出后计数归零", store6.audioMissingCount == 0)
        if let audio = after?.audioPath {
            check("补导出音轨可 ffprobe", audioStreamCount(audio) == 1, audio)
        }

        // A7 迟到的旧一轮音轨回调，不能清掉当前一轮的 staging 与子进程引用
        let stub7 = stubDirectory(slow: true, withProbe: true)
        let store7 = makeStore(root: freshRoot("a7"), tools: stub7)
        let folder7 = addCollection(store7, "迟到音轨主题")
        store7.includeAudio = true
        enqueue(store7, link("7300000000000001012") + "\n")
        store7.start()
        let inAudio7 = await wait(25) { store7.detail.contains("正在导出配套音轨") }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let liveStaging = files(folder7, suffix: ".m4a").first { $0.hasPrefix(".shiying-audio") }
        let entry7 = item(store7, "1012")?.id
        let staleStaging = folder7.appendingPathComponent(".shiying-audio-STALEE7.m4a")
        try? Data("上一轮自己的临时件".utf8).write(to: staleStaging)
        if let entry7 {
            store7.finishAudio(entry: entry7, token: UUID(), code: 0,
                               staging: staleStaging, child: Process())
        }
        check("迟到回调：确实已进入音轨阶段", inAudio7 && liveStaging != nil, store7.detail)
        check("迟到回调：当前一轮 staging 仍在", liveStaging.map {
              FileManager.default.fileExists(atPath: folder7.appendingPathComponent($0).path) } ?? false,
              liveStaging ?? "nil")
        check("迟到回调：当前一轮子进程引用仍在", store7.hasLiveChild)
        check("迟到回调：条目未被改写", item(store7, "1012")?.audioPath == nil
              && item(store7, "1012")?.status == .completed, item(store7, "1012")?.status.title ?? "nil")
        check("迟到回调：只处置自己那份临时件", !FileManager.default.fileExists(atPath: staleStaging.path))
        _ = await wait(25) { store7.isRunning == false }
        let settled = item(store7, "1012")
        check("迟到回调后本轮仍正常收尾", settled?.audioPath != nil || settled?.audioError != nil,
              settled?.audioError ?? "nil")
        check("收尾后无残留 staging",
              files(folder7, suffix: ".m4a").filter { $0.hasPrefix(".shiying-audio") }.isEmpty,
              files(folder7, suffix: ".m4a").joined(separator: ","))
    }

    func stubDirectory(slow: Bool, withProbe: Bool) -> URL {
        let dir = bundleDir.appendingPathComponent(withProbe ? (slow ? "stub-slow" : "stub-noprobe") : "stub-noprobe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ffmpeg = dir.appendingPathComponent("ffmpeg")
        let script = """
        #!/bin/zsh
        # 测试用 ffmpeg 替身：先建自己的 staging 文件，再慢一点退出，用于取消与缺探针场景。
        out="${@[-1]}"
        : > "$out"
        echo "stub-m4a-payload" >> "$out"
        sleep \(slow ? "2" : "0.2")
        exit 0
        """
        try? script.write(to: ffmpeg, atomically: true, encoding: .utf8)
        chmod(ffmpeg.path, 0o755)
        if withProbe {
            try? FileManager.default.copyItem(at: tools.appendingPathComponent("ffprobe"),
                                              to: dir.appendingPathComponent("ffprobe"))
        }
        return dir
    }

    // MARK: - 重启恢复（两次独立进程）

    func leaveRunning() async {
        // 先清根，保证 restore 那一次读到的就是本轮留下的一条 running，不与历史叠加。
        let root = freshRoot("relaunch")
        let store = makeStore(root: root)
        _ = addCollection(store, "重启主题")
        store.includeAudio = true
        enqueue(store, link("7300000000000004001") + "\n")
        store.start()
        _ = await wait(8) { item(store, "4001")?.status == .running }
        // 不调用 shutdown：直接退出进程，让 batch-library.json 留下一条 running，模拟崩溃/强退。
        print("LEFT-RUNNING " + (item(store, "4001")?.status.title ?? "?"))
        exit(0)
    }

    func checkRestore() {
        let root = bundleDir.appendingPathComponent("root-relaunch")
        let store = makeStore(root: root)
        let restored = store.items.first { $0.link.hasSuffix("4001") }
        check("重启后 running 变待处理", restored?.status == .pending, restored?.status.title ?? "nil")
        check("重启有明确提示", (store.notice ?? "").contains("待处理"), store.notice ?? "nil")
        check("重启不自动联网", store.isRunning == false)
        check("主题与条目已恢复", store.collections.count == 1 && store.items.count == 1,
              "collections=\(store.collections.count) items=\(store.items.count)")
        check("音轨开关不恢复误判", restored?.wantsAudio == true)
        let resolved = restored?.importID.flatMap { id in store.imports.first { $0.id == id } }
        check("原文批次跨重启仍在且可解析", resolved != nil,
              "imports=\(store.imports.count) importID=\(restored?.importID != nil)")
    }
}
