import Foundation

// 拾影批量内核自检：Foundation only，单文件可编译运行。
//   swiftc -swift-version 5 -target arm64-apple-macosx14.0 Sources/BatchCore.swift Tests/BatchCoreChecks.swift \
//     -o build/batch-A/checks && build/batch-A/checks
// 只写 build/batch-A/tmp/ 下的临时目录，不碰正式 App 数据、不联网。
// 音轨裁决（contract.md:3-11）后：不为已取消的 Markdown 学习包/提示词/备注 UI 写测试。

var passed = 0
var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1 }
    else { failures.append("\(name) — \(detail())") }
}

func expectBatchError(_ name: String, _ expected: BatchError, _ body: () throws -> Void) {
    do { try body(); failures.append("\(name) — 期望抛错 \(expected)，实际未抛错") }
    catch let error as BatchError {
        if error == expected { passed += 1 }
        else { failures.append("\(name) — 期望 \(expected)，实际 \(error)") }
    }
    catch { failures.append("\(name) — 期望 BatchError，实际 \(error)") }
}

func expectThrows(_ name: String, _ body: () throws -> Void) {
    do { try body(); failures.append("\(name) — 期望抛错，实际未抛错") }
    catch { passed += 1 }
}

let fm = FileManager.default
let runDir = URL(fileURLWithPath: "build/batch-A/tmp/run-\(UUID().uuidString.prefix(8))", isDirectory: true)
func scratch(_ name: String) -> URL {
    let url = runDir.appendingPathComponent(name, isDirectory: true)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
let idA = "7000000000000000001"
let idB = "7000000000000000002"
let videoA = "https://www.douyin.com/video/\(idA)"

// MARK: - 1 解析与规范化

func parsingChecks() {
    let cases: [(String, String?)] = [
        (videoA, videoA),
        ("https://www.douyin.com/note/\(idA)", videoA),
        ("https://www.iesdouyin.com/share/video/\(idA)/", videoA),
        ("https://douyin.com/video/\(idA)?x=1", videoA),
        ("HTTPS://WWW.DOUYIN.COM/VIDEO/\(idA)", videoA),
        (idA, videoA),
        ("  \(idB)  ", "https://www.douyin.com/video/\(idB)"),
        ("https://v.douyin.com/iAbCdEf/?share=1&x=2", "https://v.douyin.com/iAbCdEf/"),
        ("http://v.douyin.com/iAbCdEf/", "https://v.douyin.com/iAbCdEf/"),
        ("https://www.douyin.com/user/self", "https://www.douyin.com/user/self"),
        ("https://douyin.com.evil.test/video/\(idA)", nil),
        ("https://www.douyin.com.evil.test/", nil),
        ("https://evil.test/#https://www.douyin.com/video/\(idA)", nil),
        ("https://x@evil.test/", nil),
        ("https://www.tiktok.com/@user/video/\(idA)", nil),
        ("https://youtube.com/watch?v=abc", nil),
        ("复制此链接打开抖音 \(idA)abc", nil),
        ("", nil),
    ]
    for (input, expected) in cases {
        check("normalize(\(input.isEmpty ? "空串" : input))", BatchLinkParser.normalize(input) == expected,
              "得到 \(String(describing: BatchLinkParser.normalize(input)))，期望 \(String(describing: expected))")
    }
    check("videoID(from:)", BatchLinkParser.videoID(from: videoA) == idA)
    check("videoID(短链) 为 nil", BatchLinkParser.videoID(from: "https://v.douyin.com/iAbCdEf/") == nil)
    check("videoID(20位) 视为非法", BatchLinkParser.videoID(from: "https://www.douyin.com/video/\(idA)7") == nil)
    check("四平台链接白名单与worker对应", BatchLinkParser.allowedHosts == Set([
        "v.douyin.com", "www.douyin.com", "douyin.com", "www.iesdouyin.com", "iesdouyin.com",
        "www.bilibili.com", "bilibili.com", "space.bilibili.com", "b23.tv",
        "www.xiaohongshu.com", "xiaohongshu.com", "xhslink.com", "www.xhslink.com",
        "channels.weixin.qq.com", "weixin.qq.com", "www.weixin.qq.com"
    ]))
    let bv = "https://www.bilibili.com/video/BV13x41117TL/?spm_id_from=333"
    check("B站BV链接规范化", BatchLinkParser.normalize(bv) == "https://www.bilibili.com/video/BV13x41117TL")
    check("B站指定分P保留", BatchLinkParser.normalize(bv + "&p=2") == "https://www.bilibili.com/video/BV13x41117TL?p=2")
    check("B站不同分P不会去重掉", BatchLinkParser.identity(for: bv + "&p=1") != BatchLinkParser.identity(for: bv + "&p=2"))
    check("B站av链接", BatchLinkParser.videoID(from: "https://www.bilibili.com/video/av42/") == "av42")
    check("B站域名伪装拒绝", BatchLinkParser.normalize("https://www.bilibili.com.evil.test/video/BV13x41117TL") == nil)
    let note = "https://www.xiaohongshu.com/explore/6381a8c0000000001f00c4ae?xsec_token=abc%2Bdef&xsec_source=pc_feed&tracking=1"
    let normalizedNote = BatchLinkParser.normalize(note)
    check("小红书签名必须保留", normalizedNote?.contains("xsec_token=abc%2Bdef") == true && normalizedNote?.contains("tracking") == false)
    check("小红书作品ID", BatchLinkParser.videoID(from: note) == "6381a8c0000000001f00c4ae")
    let wx1 = "https://channels.weixin.qq.com/platform#shiying-capture-web-one"
    let wx2 = "https://channels.weixin.qq.com/platform#shiying-capture-web-two"
    check("视频号同网页的不同作品独立", BatchLinkParser.normalize(wx1) != BatchLinkParser.normalize(wx2))
    check("视频号编号保留", BatchLinkParser.videoID(from: wx1) == "web-one")
    check("跨平台作品ID互不复用", BatchLinkParser.identity(for: bv, videoID: "same") != BatchLinkParser.identity(for: videoA, videoID: "same"))
    check("URL用户密码不接受", BatchLinkParser.normalize("https://user:pass@www.bilibili.com/video/BV13x41117TL") == nil)
}

// MARK: - 2 全量提取、去重、计数与原文映射

func previewChecks() {
    let multi = """
    7.43 复制打开抖音，看看【作者的作品】原文案 https://v.douyin.com/iAAA/ 复制此链接
    \(videoA)
    https://www.douyin.com/note/\(idB)?ref=x
    https://douyin.com.evil.com/video/123
    这行只有中文没有链接
    \(idA)
    """
    let preview = try? BatchLinkParser.preview(multi)
    check("多行混排可解析", preview != nil, "抛错：\(String(describing: preview))")
    check("全量提取且保序", preview?.links == ["https://v.douyin.com/iAAA/", videoA, "https://www.douyin.com/video/\(idB)"],
          "实际 \(String(describing: preview?.links))")
    check("同次内重复计 1 条", preview?.duplicateCount == 1, "实际 \(String(describing: preview?.duplicateCount))")
    check("坏主机+纯文字行 = invalidCount 2", preview?.invalidCount == 2, "实际 \(String(describing: preview?.invalidCount))")
    check("空行不计入 invalidCount", (try? BatchLinkParser.preview("\n\n  \n\(videoA)\n"))?.invalidCount == 0)

    // sourceTexts：key=规范 link，value=首条原始行摘录
    check("sourceTexts 每个 link 都有原文", preview?.sourceTexts.count == 3, "实际 \(String(describing: preview?.sourceTexts.keys))")
    check("sourceTexts 首条原始行", preview?.sourceTexts["https://v.douyin.com/iAAA/"]?.contains("复制打开抖音") == true,
          "实际 \(String(describing: preview?.sourceTexts["https://v.douyin.com/iAAA/"]))")
    check("sourceTexts 用规范化后的 key", preview?.sourceTexts[videoA] == videoA)
    let dupLine = try? BatchLinkParser.preview("\(videoA)\n第二次的分享文案 \(videoA)")
    check("重复 link 保留首条原文", dupLine?.sourceTexts[videoA] == videoA, "实际 \(String(describing: dupLine?.sourceTexts))")
    let twoLinks = try? BatchLinkParser.preview("一行两条 \(videoA) 和 https://www.douyin.com/video/\(idB)")
    check("一行两链接共享该行原文",
          twoLinks?.sourceTexts[videoA] == "一行两条 \(videoA) 和 https://www.douyin.com/video/\(idB)"
          && twoLinks?.sourceTexts["https://www.douyin.com/video/\(idB)"] == "一行两条 \(videoA) 和 https://www.douyin.com/video/\(idB)",
          "实际 \(String(describing: twoLinks?.sourceTexts))")
    let longLine = String(repeating: "标", count: 4000) + " " + videoA   // 12000 字节 + 链接
    let capped = try? BatchLinkParser.preview(longLine)
    check("摘录不超 4096 字节且尽量填满", (4090...4096).contains(capped?.sourceTexts[videoA]?.utf8.count ?? -1),
          "实际 \(String(describing: capped?.sourceTexts[videoA]?.utf8.count))")
    check("摘录不切断字素簇", capped?.sourceTexts[videoA]?.hasPrefix("标标标") == true
          && String(decoding: (capped?.sourceTexts[videoA] ?? "").utf8, as: UTF8.self) == capped?.sourceTexts[videoA])
    check("excerpt 短文本原样", BatchLinkParser.excerpt("短", limit: 100) == "短")
    check("excerpt 不切 emoji", BatchLinkParser.excerpt("🚀🚀", limit: 5) == "🚀")

    let againstExisting = try? BatchLinkParser.preview("\(videoA)\nhttps://www.douyin.com/video/\(idB)", existing: [videoA])
    check("对 existing 去重", againstExisting?.links == ["https://www.douyin.com/video/\(idB)"] && againstExisting?.duplicateCount == 1,
          "实际 \(String(describing: againstExisting))")
    let twoURLs = try? BatchLinkParser.preview("看这个 \(videoA) 还有 https://v.douyin.com/iBBB/")
    check("一行两条 URL 全取", twoURLs?.links.count == 2, "实际 \(String(describing: twoURLs?.links))")
    check("尾部中文标点被剥掉", (try? BatchLinkParser.preview("\(videoA)，。！）"))?.links == [videoA])
    check("反斜杠转义冒号可识别", (try? BatchLinkParser.preview("https\\://www.douyin.com/video/\(idA)"))?.links == [videoA])
    // 预览可见性补充：全量重复要返回空 links + 正确计数，不能抛 emptyInput 掩盖诊断
    let allDup = try? BatchLinkParser.preview("\(videoA)\nhttps://www.douyin.com/note/\(idA)", existing: [videoA])
    check("全量重复不抛错", allDup != nil, "实际 \(String(describing: allDup))")
    check("全量重复 links 为空", allDup?.links.isEmpty == true, "实际 \(String(describing: allDup?.links))")
    check("全量重复 duplicateCount 为 2", allDup?.duplicateCount == 2, "实际 \(String(describing: allDup?.duplicateCount))")
    check("全量重复 invalidCount 为 0", allDup?.invalidCount == 0, "实际 \(String(describing: allDup?.invalidCount))")
    let dupOnly = try? BatchLinkParser.preview("\(videoA)\n\(videoA)")
    check("同次内重复保留首条并计 1 次重复", dupOnly?.links == [videoA] && dupOnly?.duplicateCount == 1
          && dupOnly?.invalidCount == 0, "实际 \(String(describing: dupOnly))")
    let dupMixed = try? BatchLinkParser.preview("纯文字一行\n\(videoA)", existing: [videoA])
    check("重复+坏行：links 空但 invalidCount 保留", dupMixed?.links.isEmpty == true
          && dupMixed?.duplicateCount == 1 && dupMixed?.invalidCount == 1, "实际 \(String(describing: dupMixed))")
    expectBatchError("空输入抛 emptyInput", .emptyInput) { _ = try BatchLinkParser.preview("   \n\t\n") }
    expectBatchError("全坏主机抛 emptyInput（不静默给空表）", .emptyInput) {
        _ = try BatchLinkParser.preview("https://evil.test/a\n纯文字一行")
    }
}

// MARK: - 3 上限（拒绝而非截断）

func limitChecks() {
    let big = String(repeating: "a", count: BatchLimits.maxTextBytes + 1)
    expectBatchError("超 5MiB 拒绝", .textTooLarge(utf8Bytes: BatchLimits.maxTextBytes + 1, limit: BatchLimits.maxTextBytes)) {
        _ = try BatchLinkParser.preview(big)
    }
    let exactlyMax = String(repeating: "a", count: BatchLimits.maxTextBytes - videoA.utf8.count - 1) + "\n" + videoA
    check("恰好 5MiB 放行", (try? BatchLinkParser.preview(exactlyMax))?.links == [videoA], "字节数 \(exactlyMax.utf8.count)")

    let makeLinks = { (count: Int) in
        (0..<count).map { "https://www.douyin.com/video/70000000000000000\(String(format: "%02d", $0))" }.joined(separator: "\n")
    }
    check("5000 条放行", (try? BatchLinkParser.preview(makeLinks(BatchLimits.maxLinks)))?.links.count == BatchLimits.maxLinks)
    expectBatchError("5001 条整批拒绝", .tooManyLinks(count: BatchLimits.maxLinks + 1, limit: BatchLimits.maxLinks)) {
        _ = try BatchLinkParser.preview(makeLinks(BatchLimits.maxLinks + 1))
    }
}

// MARK: - 4 持久化

func repositoryChecks() {
    let root = scratch("lib")
    let repo = BatchRepository(rootURL: root)
    check("无文件 load 返回空库", (try? repo.load())?.items.isEmpty == true && (try? repo.load())?.imports.isEmpty == true)
    check("空 load 不落盘", !fm.fileExists(atPath: root.appendingPathComponent("batch-library.json").path))

    var state = BatchLibraryState()
    let collection = StudyCollection(name: "考研政治", path: root.appendingPathComponent("考研政治").path)
    var item = BatchItem(collectionID: collection.id, link: videoA, sourceText: "分享文案 \(videoA)", qualityRaw: "720")
    item.status = .completed
    item.title = "标题，含逗号\"引号\"与\n换行"
    item.author = "作者"
    item.description = "=HYPERLINK(\"http://evil\")"
    item.videoID = idA
    item.path = "\(collection.path)/a.mp4"
    item.width = 1080; item.height = 1920; item.duration = 62.5; item.bytes = 12345678
    let source = BatchImportSource(collectionID: collection.id, text: "分享文案 \(videoA)")
    item.importID = source.id
    state.collections = [collection]
    state.items = [item]
    state.imports = [source]
    check("save 成功", (try? repo.save(state)) != nil)
    let once = (try? repo.load()) ?? BatchLibraryState()
    try? repo.save(once)
    let twice = (try? repo.load()) ?? BatchLibraryState()
    check("save/load 逐位往返一致（日期用 deferredToDate 无损）",
          once.collections == state.collections && once.items == state.items && once.imports == state.imports,
          "collections \(once.collections == state.collections) items \(once.items == state.items) imports \(once.imports == state.imports)")
    check("日期精确往返：回读 Date 与原值 timeIntervalSinceReferenceDate 完全相等",
          zip(once.items, state.items).allSatisfy { a, b in
              a.createdAt.timeIntervalSinceReferenceDate == b.createdAt.timeIntervalSinceReferenceDate
          } && once.collections.first?.createdAt == collection.createdAt,
          "原 \(String(describing: state.items.first?.createdAt.timeIntervalSinceReferenceDate)) 回 \(String(describing: once.items.first?.createdAt.timeIntervalSinceReferenceDate))")
    check("除日期外其余字段也未被改写", once.items.first?.title == item.title && once.items.first?.description == item.description
          && once.items.first?.audioError == item.audioError && once.imports.first?.text == source.text)
    check("二次 save 幂等（时间戳不再漂移）", twice.items == once.items && twice.imports == once.imports)
    check("save 只写 batch-library.json",
          (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() == ["batch-library.json"],
          "实际 \(String(describing: try? fm.contentsOfDirectory(atPath: root.path)))")
    let onDisk = (try? String(contentsOf: root.appendingPathComponent("batch-library.json"), encoding: .utf8)) ?? ""
    check("schemaVersion 落盘为 1", onDisk.contains("\"schemaVersion\" : 1"))
    check("imports 字段名落盘", onDisk.contains("\"imports\"") && onDisk.contains("\"importID\""))

    let fileURL = root.appendingPathComponent("batch-library.json")
    try? "{ not json".data(using: .utf8)?.write(to: fileURL)
    expectThrows("损坏库 load 抛错而非当空库") { _ = try repo.load() }
    expectBatchError("损坏库 save 拒绝覆盖", .refusedOverwriteCorrupted(path: fileURL.path)) { try repo.save(BatchLibraryState()) }
    check("拒绝覆盖后损坏文件原样保留", (try? Data(contentsOf: fileURL))?.count == 10, "实际 \(String(describing: (try? Data(contentsOf: fileURL))?.count))")
    try? (try? BatchRepository.encoder.encode(state))?.write(to: fileURL)
    check("修回后可正常 load", (try? repo.load())?.items.count == 1)

    let nested = scratch("nested/deeper")
    check("root 不存在时 save 自动建目录", (try? BatchRepository(rootURL: nested).save(state)) != nil)
    let readOnly = scratch("readonly")
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
    let blocked = readOnly.appendingPathComponent("sub")
    do { try BatchRepository(rootURL: blocked).save(state); failures.append("只读目录应写失败但成功了") }
    catch let error as BatchError {
        if case .writeFailed = error { passed += 1 } else { failures.append("只读目录抛了 \(error)") }
    }
    catch { failures.append("只读目录抛了非 BatchError：\(error)") }
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
}

// MARK: - 5 收集目录

func collectionChecks() {
    let parent = scratch("collections")
    let first = try? BatchRepository.createCollection(name: "机器学习 笔记", parent: parent, existing: [])
    check("创建真实子目录", fm.fileExists(atPath: first?.path ?? "") && first?.name == "机器学习 笔记", "实际 \(String(describing: first))")
    check("目录在 parent 下", first?.path == parent.appendingPathComponent("机器学习 笔记").path)

    let sentinel = (first?.path ?? "") + "/旧文件.mp4"
    try? "keep".data(using: .utf8)?.write(to: URL(fileURLWithPath: sentinel))
    let second = try? BatchRepository.createCollection(name: "机器学习 笔记", parent: parent, existing: [])
    check("重名自动加唯一后缀", second?.name == "机器学习 笔记-2" && second?.path != first?.path, "实际 \(String(describing: second?.name))")
    check("旧目录内容未被覆盖或挪走", fm.fileExists(atPath: sentinel) && (try? String(contentsOfFile: sentinel, encoding: .utf8)) == "keep")
    let third = try? BatchRepository.createCollection(name: "机器学习 笔记", parent: parent, existing: [first!, second!])
    check("与 existing 列表也去重", third?.name == "机器学习 笔记-3", "实际 \(String(describing: third?.name))")
    check("名称含 emoji 与点号可用", (try? BatchRepository.createCollection(name: "AI.进阶🚀", parent: parent, existing: []))?.name == "AI.进阶🚀")
    check("两端空白被裁掉", (try? BatchRepository.createCollection(name: "  四轴  ", parent: parent, existing: []))?.name == "四轴")

    for (name, label) in [("a/b", "/"), ("a\\b", "\\"), ("a\u{0007}b", "BEL"), ("a\u{0000}b", "NUL"),
                          (".", "点"), ("..", "点点"), ("   ", "空白"), ("", "空")] {
        expectThrows("拒绝非法名称（\(label)）") { _ = try BatchRepository.createCollection(name: name, parent: parent, existing: []) }
    }
    let longName = String(repeating: "标", count: 91)
    expectBatchError("超长名称按 UTF-8 拒绝", .collectionPathTooLong(utf8Bytes: longName.utf8.count, limit: BatchLimits.maxNameBytes)) {
        _ = try BatchRepository.createCollection(name: longName, parent: parent, existing: [])
    }
    let fileAsParent = parent.appendingPathComponent("不是目录")
    try? "x".data(using: .utf8)?.write(to: fileAsParent)
    expectThrows("parent 是文件时拒绝") { _ = try BatchRepository.createCollection(name: "ok", parent: fileAsParent, existing: []) }
    check("非法名称不会留下半成品目录", (try? fm.contentsOfDirectory(atPath: parent.path))?.contains("a/b") != true)
}

// MARK: - 6 索引导出（音轨裁决后只有 CSV/JSON）

func exportChecks() {
    let parent = scratch("export-parent")
    guard let collection = try? BatchRepository.createCollection(name: "考研英语", parent: parent, existing: []) else {
        failures.append("导出前置：建集合失败"); return
    }
    let batch = BatchImportSource(collectionID: collection.id, text: "整批原始文本\n第一行 \(videoA)\n第二行 https://v.douyin.com/iCCC/")
    var a = BatchItem(collectionID: collection.id, link: videoA, sourceText: "第一行 \(videoA)", qualityRaw: "highest")
    a.status = .completed; a.title = "长难句精讲"; a.author = "老师甲"; a.description = "=SUM(1,2)×公式注入"
    a.videoID = idA; a.path = "\(collection.path)/a.mp4"; a.width = 1080; a.height = 1920; a.duration = 123.5; a.bytes = 9_999_999
    a.importID = batch.id
    a.audioPath = "\(collection.path)/a.m4a"
    var b = BatchItem(collectionID: collection.id, link: "https://v.douyin.com/iCCC/", sourceText: "第二行 https://v.douyin.com/iCCC/", qualityRaw: "720")
    b.status = .failed; b.error = "解析超时"; b.importID = batch.id
    b.audioError = "该视频没有音轨"
    b.description = "含\"引号\"和,逗号\n与换行"
    var foreign = BatchItem(collectionID: UUID(), link: "https://www.douyin.com/video/\(idB)", sourceText: "别的主题")
    foreign.status = .completed
    let media = "\(collection.path)/a.mp4"
    try? "video-bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: media))

    let dir = try? BatchRepository.export(collection: collection, items: [a, b, foreign], imports: [batch])
    check("导出返回新目录", dir != nil && fm.fileExists(atPath: dir?.path ?? ""))
    check("目录名形如 学习资料-时间-UUID",
          dir?.lastPathComponent.hasPrefix("学习资料-") == true && dir?.lastPathComponent.split(separator: "-").count == 4,
          "实际 \(String(describing: dir?.lastPathComponent))")
    check("导出落在本 collection 内", dir?.deletingLastPathComponent().path == collection.path)
    let names = (try? fm.contentsOfDirectory(atPath: dir?.path ?? ""))?.sorted() ?? []
    check("只产出 CSV/JSON 两份，学习包文件不再生成",
          names == ["资料.csv", "资料.json"], "实际 \(names)")
    check("导出没动已存在视频与音轨", (try? String(contentsOfFile: media, encoding: .utf8)) == "video-bytes")

    let csvText = (try? String(contentsOf: dir?.appendingPathComponent("资料.csv") ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""
    let csvURL = dir?.appendingPathComponent("资料.csv") ?? URL(fileURLWithPath: "/dev/null")
    let csvHead: [UInt8] = Array((try? Data(contentsOf: csvURL))?.prefix(3) ?? Data())
    check("CSV 带 BOM", csvHead == [0xEF, 0xBB, 0xBF], "实际 \(csvHead)")
    check("CSV 用 CRLF", csvText.contains("\r\n"))
    let header = csvText.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).split(separator: "\r\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    check("CSV 表头含音轨三列", header.contains("音轨开关") && header.contains("音轨路径") && header.contains("音轨错误"), "实际 \(header)")
    check("CSV 表头含原文批次列", header.contains("原文批次"))
    let dateColumn = csvText.split(separator: "\r\n", omittingEmptySubsequences: true).dropFirst(1).first.map(String.init)?
        .components(separatedBy: ",")[15] ?? ""
    check("CSV 入队时间列是人类可读格式", dateColumn.range(of: "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) != nil,
          "实际 \(dateColumn)")
    check("CSV 行数 = 表头 + 2 条（不串主题）", csvText.split(separator: "\r\n", omittingEmptySubsequences: true).count == 3,
          "实际 \(csvText.split(separator: "\r\n", omittingEmptySubsequences: true).count)")
    check("CSV 不含别的主题的条目", !csvText.contains("别的主题") && !csvText.contains(idB))
    check("CSV 公式注入字段：前缀单引号 + 整体引号", csvText.contains("\"'=SUM(1,2)×公式注入\""), "实际 \(csvText)")
    check("CSV 内嵌引号翻倍且整体包引号", csvText.contains("\"含\"\"引号\"\"和,逗号\n与换行\""), "实际 \(csvText)")
    check("CSV 音轨状态可见", csvText.contains("a.m4a") && csvText.contains("该视频没有音轨") && csvText.contains("开"))

    let jsonText = (try? String(contentsOf: dir?.appendingPathComponent("资料.json") ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""
    struct ImportRow: Decodable { let id: UUID; let utf8Bytes: Int; let itemCount: Int }
    struct IndexShape: Decodable { let schemaVersion: Int; let items: [BatchItem]; let importIndex: [ImportRow] }
    let decoded = try? BatchRepository.decoder.decode(IndexShape.self, from: Data(jsonText.utf8))
    check("JSON 可回解且只含本主题", decoded?.items.count == 2 && decoded?.items.allSatisfy { $0.collectionID == collection.id } == true,
          "实际 \(String(describing: decoded?.items.count))")
    check("JSON 保留 importID 引用", decoded?.items.first?.importID == batch.id)
    check("JSON 导入索引只列批次不重复全文", decoded?.importIndex.count == 1
          && decoded?.importIndex.first?.utf8Bytes == batch.text.utf8.count
          && decoded?.importIndex.first?.itemCount == 2 && !jsonText.contains("整批原始文本"))
    check("JSON 保留音轨字段", jsonText.contains("\"audioPath\"") && jsonText.contains("\"audioError\"") && jsonText.contains("\"wantsAudio\""))

    let second = try? BatchRepository.export(collection: collection, items: [a, b, foreign], imports: [batch])
    check("二次导出是新目录、不覆盖旧导出", second != nil && second != dir
          && (try? fm.contentsOfDirectory(atPath: dir?.path ?? ""))?.count == 2)
    check("空 items 也能导出", (try? BatchRepository.export(collection: collection, items: [], imports: [])) != nil)
    check("省略 imports 参数仍可调用（默认值）", (try? BatchRepository.export(collection: collection, items: [a])) != nil)

    let ghost = StudyCollection(name: "不存在", path: parent.appendingPathComponent("不存在").path)
    expectBatchError("集合目录缺失时拒绝导出", .collectionPathMissing(ghost.path)) {
        _ = try BatchRepository.export(collection: ghost, items: [], imports: [])
    }
}

// MARK: - 7 音轨字段：默认值与编解码（实现归 B，A 只管字段）

func audioFieldChecks() {
    let collection = StudyCollection(name: "x", path: "/tmp/does-not-matter-a")
    let item = BatchItem(collectionID: collection.id, link: videoA, sourceText: "原文")
    check("wantsAudio 默认为 true", item.wantsAudio == true)
    check("audioPath 默认 nil", item.audioPath == nil)
    check("audioError 默认 nil", item.audioError == nil)

    var off = item
    off.wantsAudio = false
    off.audioPath = "/tmp/does-not-matter-a/a.m4a"
    off.audioError = "该视频没有音轨"
    let data = try? BatchRepository.encoder.encode([off])
    let back = try? BatchRepository.decoder.decode([BatchItem].self, from: data ?? Data())
    check("音轨字段编解码往返", back?.first == off, "实际 \(String(describing: back?.first))")
    let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
    check("音轨字段以原名落 JSON", text.contains("\"wantsAudio\" : false") && text.contains("\"audioPath\"") && text.contains("\"audioError\""))

    // 旧库（无音轨字段）解码时要用默认值补齐，不能让整库解码失败
    let legacy = "[{\"id\":\"\(UUID().uuidString)\",\"collectionID\":\"\(UUID().uuidString)\",\"link\":\"\(videoA)\",\"sourceText\":\"\",\"qualityRaw\":\"highest\",\"status\":\"pending\",\"title\":\"等待解析\",\"author\":\"\",\"description\":\"\",\"width\":0,\"height\":0,\"duration\":0,\"bytes\":0,\"createdAt\":812345678.5}]"
    let decodedLegacy = try? BatchRepository.decoder.decode([BatchItem].self, from: Data(legacy.utf8))
    check("缺音轨字段的旧条目可解码", decodedLegacy?.count == 1 && decodedLegacy?.first?.wantsAudio == true,
          "实际 \(String(describing: decodedLegacy?.first?.wantsAudio))")
    check("BatchItem 仍是 Equatable/Identifiable", off != item && off.id == off.id)

    // 本轮加过 imports / notes 字段：早先写下的库文件缺键也必须能打开，不能判整库损坏
    let legacyLibrary = "{\"schemaVersion\":1,\"collections\":[{\"id\":\"\(UUID().uuidString)\",\"name\":\"旧主题\",\"path\":\"/tmp/old\"}],\"items\":[]}"
    let legacyDecoded = try? BatchRepository.decoder.decode(BatchLibraryState.self, from: Data(legacyLibrary.utf8))
    check("缺 imports 键的旧库可解码", legacyDecoded?.imports.isEmpty == true && legacyDecoded?.collections.count == 1,
          "实际 \(String(describing: legacyDecoded))")
    check("缺 notes/createdAt 的旧主题取默认值", legacyDecoded?.collections.first?.notes == ""
          && legacyDecoded?.collections.first?.createdAt != nil)
    let bareLibrary = "{}"
    check("空对象解码成空库", (try? BatchRepository.decoder.decode(BatchLibraryState.self, from: Data(bareLibrary.utf8)))?.items.isEmpty == true)
}

// MARK: - 8 大批量：全文只存一份

func memoryChecks() {
    let collection = StudyCollection(name: "大批量", path: "/tmp/does-not-matter-b")
    let huge = String(repeating: "分", count: 200_000)   // 600KB 级整批原文
    let links = (0..<500).map { "https://www.douyin.com/video/700000000000000\(String(format: "%03d", $0))" }
    let batch = BatchImportSource(collectionID: collection.id, text: huge + "\n" + links.joined(separator: "\n"))
    let items = links.map { link -> BatchItem in
        var item = BatchItem(collectionID: collection.id, link: link, sourceText: BatchLinkParser.excerpt("分享文案 \(link)"))
        item.importID = batch.id
        return item
    }
    var state = BatchLibraryState()
    state.collections = [collection]
    state.items = items
    state.imports = [batch]
    let data = (try? BatchRepository.encoder.encode(state)) ?? Data()
    check("500 条只存 1 份全文", state.imports.count == 1 && Set(items.compactMap(\.importID)).count == 1)
    check("条目摘录各自可回溯", items.allSatisfy { $0.sourceText.contains($0.link) })
    check("库文件不随条目数复制全文", data.count < batch.text.utf8.count + 500 * 4096,
          "库 \(data.count) 字节，1 份全文 \(batch.text.utf8.count) + 500 条摘录上限 \(500 * 4096)")
    check("500 条摘录实际远小于上限", items.reduce(0) { $0 + $1.sourceText.utf8.count } < 500 * 100,
          "实际 \(items.reduce(0) { $0 + $1.sourceText.utf8.count }) 字节")
    check("全文按 importID 可取回", items.first.flatMap { first -> String? in
        state.imports.first(where: { $0.id == first.importID })?.text
    }?.hasPrefix(huge.prefix(200)) == true)
    let worstCase = 5000 * BatchLimits.sourceExcerptBytes
    check("5000 条摘录上限约 20MiB 而非 25GiB", worstCase == 20_480_000 && 5000 * BatchLimits.maxTextBytes == 26_214_400_000)

    let root = scratch("memory")
    let repo = BatchRepository(rootURL: root)
    check("大批量 save/load 一致", (try? repo.save(state)) != nil && (try? repo.load())?.items.count == 500
          && (try? repo.load())?.imports.first?.text == batch.text)
}

@main struct BatchCoreChecks {
    static func main() {
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        parsingChecks()
        previewChecks()
        limitChecks()
        repositoryChecks()
        collectionChecks()
        exportChecks()
        audioFieldChecks()
        memoryChecks()
        print("BatchCoreChecks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("  FAIL \(failure)") }
        print("scratch 保留于 \(runDir.path)")
        if failures.isEmpty { print("ALL_OK") } else { exit(1) }
    }
}
