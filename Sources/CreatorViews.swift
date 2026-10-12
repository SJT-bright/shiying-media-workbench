import SwiftUI
import AppKit

// 博主采集。万和日期只交给 CreatorCore；这里不换算、不改非法值为不限。
// 下载走 BatchStore.enqueueCreatorPosts，不在本文件声明这个方法。
// 按任务顺序纵向排列，统一标签列。设置与结果共用一条滚动轴，下载按钮固定在底部。
// 链接卡只重排标题行：登录页 / 清除登录状态，视频号则是官方网页 / 元宝入口。
// 扫描、取消、继续仍在链接下方。日期行和其它筛选不在这次改动里。

struct ShiyingCreatorView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var batch: BatchStore
    @EnvironmentObject private var creator: CreatorStore
    @Environment(\.colorScheme) private var scheme

    @State private var hydrated = false
    @State private var fromOn = false
    @State private var toOn = false
    @State private var fromText = ""
    @State private var toText = ""
    @State private var likesOn = false
    @State private var likesText = ""
    @State private var likesError: String?
    @State private var collectsOn = false
    @State private var collectsText = ""
    @State private var collectsError: String?
    @State private var pasteNote: String?
    private enum LoginRequest: String, Identifiable {
        case official, parser
        var id: String { rawValue }
    }
    @State private var loginRequest: LoginRequest?

    private var palette: QQPalette { QQPalette(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    platformPicker
                    linkCard
                    filterCard
                    folderCard
                    exportCard
                    results
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ctaBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: hydrate)
        .sheet(item: $loginRequest) { request in
            CreatorLoginView(
                url: request == .parser ? MediaPlatform.wechatParserLoginURL : creator.homepageURL ?? (MediaPlatform.detect(link: creator.urlText) == creator.platform ? MediaPlatform.firstURL(in: creator.urlText) : nil) ?? creator.platform.loginURL,
                name: creator.creatorName,
                willResume: request == .parser ? MediaPlatform.detect(link: creator.urlText) == .wechat : creator.homepageURL != nil,
                platform: creator.platform,
                parserLogin: request == .parser
            ) { data in
                loginRequest = nil
                creator.useSession(data)
            }
        }
    }

    private var platformPicker: some View {
        HStack(spacing: 10) {
            ForEach(MediaPlatform.allCases) { platform in
                Button {
                    creator.selectPlatform(platform)
                    pasteNote = nil
                    fromOn = false; toOn = false; likesOn = false; collectsOn = false
                    fromText = ""; toText = ""; likesText = ""; collectsText = ""
                    likesError = nil; collectsError = nil
                } label: {
                    Label(platform.title, systemImage: platform.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QQSoftButtonStyle(tint: creator.platform == platform ? QQTheme.cyan : .secondary))
                .overlay { if creator.platform == platform { RoundedRectangle(cornerRadius: 14).stroke(QQTheme.cyan.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false) } }
                .disabled(creator.isScanning)
                .accessibilityLabel("切换到\(platform.title)")
                .accessibilityValue(creator.platform == platform ? "已选中" : "未选中")
            }
        }
    }

    private func sectionHeader(_ number: String, _ title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(QQTheme.cyan)
                .frame(width: 28, height: 28)
                .shiyingGlass(radius: 8, tint: QQTheme.cyan.opacity(0.08), inset: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }

    private var flowRow: some View {
        HStack(spacing: 10) {
            Text(creator.creatorName.isEmpty ? "尚未采集作者" : creator.creatorName)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(scanStatLine).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            QQPill(text: completeness, tint: completenessTint, symbol: completenessSymbol, compact: true)
        }
    }

    private var linkCard: some View {
        QQDepthSurface(radius: 18, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                linkHeader
                fieldRow(creator.platform == .wechat ? "分享链接" : "主页链接") {
                    HStack(spacing: 10) {
                        TextField(creator.platform == .wechat ? "视频号分享链接，例如 https://weixin.qq.com/sph/..." : "\(creator.platform.title)主页或主页分享短链", text: $creator.urlText)
                            .textFieldStyle(ShiyingGlassFieldStyle())
                            .controlSize(.large)
                            .qqControlMotion(tint: QQTheme.cyan)
                            .disabled(creator.isScanning)
                        pasteButton
                    }
                }
                HStack(spacing: 10) {
                    scanButton
                    if creator.isScanning { cancelButton }
                    if !creator.scanComplete, creator.nextCursor?.isEmpty == false { continueButton }
                    Spacer(minLength: 8)
                }
                if creator.hasSession && !creator.needsLogin {
                    Label("\(creator.platform.title)网页登录与采集信息已保存。采集时会使用它，是否有效由平台确认。",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(QQTheme.mint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                flowRow
                if let pasteNote {
                    Text(pasteNote).font(.system(size: 12)).foregroundStyle(QQTheme.orange)
                }
                if creator.needsLogin {
                    Label(creator.detail, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 12)).foregroundStyle(QQTheme.amber)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if let error = creator.error, !error.isEmpty {
                    Text(error).font(.system(size: 12)).foregroundStyle(QQTheme.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if !creator.detail.isEmpty {
                    Text(creator.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !creator.diagnosticText.isEmpty && !creator.isScanning {
                    DisclosureGroup("问题详情") {
                        Text(creator.diagnosticText).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("复制问题详情") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(creator.diagnosticText, forType: .string)
                        }.buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                    }.font(.system(size: 12))
                }
            }
        }
    }

    /// 标题与登录入口同一行。放得下就用原按钮；放不下只换成一个账号菜单，不裁文字、不重复动作。
    private var linkHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("01")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(QQTheme.cyan)
                .frame(width: 28, height: 28)
                .shiyingGlass(radius: 8, tint: QQTheme.cyan.opacity(0.08), inset: true)
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    CreatorTitleActionLayout {
                        linkTitleText
                        linkAccountButtons
                    }
                    CreatorTitleActionLayout {
                        linkTitleText
                        linkAccountMenu
                    }
                }
                Text(linkSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var linkTitleText: some View {
        Text(creator.platform == .wechat ? "视频号分享" : "博主主页")
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var linkSubtitle: String {
        creator.platform == .wechat
            ? "粘贴视频号分享链接；先在内置窗口微信扫码登录腾讯元宝，再解析和保存。"
            : "粘贴\(creator.platform.title)主页链接，采集该博主可访问的视频。"
    }

    private var linkAccountButtons: some View {
        HStack(spacing: 8) {
            officialLoginControl(inMenu: false)
            if creator.platform == .wechat {
                parserLoginControl(inMenu: false)
            }
            if creator.hasSession {
                clearLoginControl(inMenu: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var linkAccountMenu: some View {
        Menu {
            officialLoginControl(inMenu: true)
            if creator.platform == .wechat {
                parserLoginControl(inMenu: true)
            }
            if creator.hasSession {
                clearLoginControl(inMenu: true)
            }
        } label: {
            Label("账号", systemImage: "person.crop.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    ShiyingGlassSurface(radius: 100, tint: QQTheme.cyan.opacity(0.08), inset: true, control: true)
                }
                .contentShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("账号操作，\(linkAccountMenuActions)")
        .help("账号操作，\(linkAccountMenuActions)。打开菜单后再选择，不会自动清除登录。")
    }

    private var linkAccountMenuActions: String {
        var parts = [loginButtonTitle]
        if creator.platform == .wechat { parts.append("登录元宝解析视频号") }
        if creator.hasSession { parts.append("清除登录状态") }
        return parts.joined(separator: "，")
    }

    private var officialLoginHelp: String {
        creator.hasSession
            ? "账号已在内置网页保持登录。打开可检查，或把最新登录交给采集。"
            : "在内置\(creator.platform.title)网页登录。抖音采集开始前会自动同步，不必额外保存。"
    }

    @ViewBuilder private func officialLoginControl(inMenu: Bool) -> some View {
        if inMenu {
            Button { loginRequest = .official } label: {
                Label(loginButtonTitle, systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(creator.isScanning)
            .help(officialLoginHelp)
        } else {
            Button { loginRequest = .official } label: {
                Label(loginButtonTitle, systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            .disabled(creator.isScanning)
            .help(officialLoginHelp)
        }
    }

    @ViewBuilder private func parserLoginControl(inMenu: Bool) -> some View {
        if inMenu {
            Button { loginRequest = .parser } label: {
                Label("登录元宝解析视频号", systemImage: "qrcode")
            }
            .disabled(creator.isScanning)
        } else {
            Button { loginRequest = .parser } label: {
                Label("登录元宝解析视频号", systemImage: "qrcode")
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            .disabled(creator.isScanning)
        }
    }

    /// 只在按钮动作里清除。布局、菜单标签和出现条件都不会调用它。
    @ViewBuilder private func clearLoginControl(inMenu: Bool) -> some View {
        if inMenu {
            Button("清除登录状态") { creator.clearSession() }
                .disabled(creator.isScanning)
        } else {
            Button("清除登录状态") { creator.clearSession() }
                .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
                .disabled(creator.isScanning)
        }
    }

    private var loginButtonTitle: String {
        if creator.platform == .wechat { return "视频号官方网页" }
        if creator.needsLogin { return "检查登录 / 验证" }
        if creator.hasSession { return "登录页" }
        return creator.platform == .wechat ? "打开视频号" : "登录\(creator.platform.title)"
    }

    private var pasteButton: some View {
        Button(action: pasteHome) {
            Label("粘贴", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
        .disabled(creator.isScanning)
    }

    private var scanButton: some View {
        Button { creator.scan(resume: false) } label: {
            Label(creator.isScanning ? "正在采集…" : (creator.platform == .wechat ? "解析分享链接" : "开始采集"), systemImage: "magnifyingglass")
        }
        .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
        .disabled(creator.isScanning || creator.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var cancelButton: some View {
        Button { creator.cancel() } label: {
            Label("取消扫描", systemImage: "stop.fill")
        }
        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.rose))
        .disabled(!creator.isScanning)
        .help("只停止扫描，不取消已经在下的视频。")
    }

    private var continueButton: some View {
        Button { creator.scan(resume: true) } label: {
            Label("继续", systemImage: "arrow.clockwise")
        }
        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.mint))
        .disabled(creator.isScanning || creator.scanComplete || creator.nextCursor?.isEmpty != false)
        .help("从上次游标接着采，不清已采结果。")
    }

    private var filterCard: some View {
        QQDepthSurface(radius: 18, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("02", "筛选条件", subtitle: "所有启用条件同时满足；关闭或留空表示不限。")
                fieldRow("发布时间") {
                    HStack(spacing: 16) {
                        dateEndRow("开始", on: fromToggle, text: fromBinding)
                        dateEndRow("结束", on: toToggle, text: toBinding)
                    }
                }
                fieldRow("互动门槛") {
                    HStack(spacing: 16) {
                        thresholdRow(title: "点赞 >", on: likesToggle, text: likesBinding)
                        thresholdRow(title: "收藏 >", on: collectsToggle, text: collectsBinding)
                    }
                }
                fieldRow("标题关键词") { keywordField }
                fieldRow("结果排序") { sortPicker }
                if let issue = likesError ?? collectsError ?? filterIssue {
                    Text(issue).font(.system(size: 12)).foregroundStyle(QQTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("日期包含起止当天 · 点赞和收藏严格大于填写值 · 单位：万")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keywordField: some View {
        TextField("搜索标题", text: keywordBinding)
            .textFieldStyle(ShiyingGlassFieldStyle())
            .frame(minWidth: 88, maxWidth: .infinity)
            .qqControlMotion(tint: QQTheme.cyan)
    }

    private var sortPicker: some View {
        HStack(spacing: 6) {
            ForEach(CreatorSort.allCases, id: \.rawValue) { item in
                Button { sortBinding.wrappedValue = item.rawValue } label: {
                    Text(sortTitle(item.rawValue)).frame(minWidth: 42)
                }
                .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan, selected: sortBinding.wrappedValue == item.rawValue))
                .accessibilityLabel(sortTitle(item.rawValue))
                .accessibilityAddTraits(sortBinding.wrappedValue == item.rawValue ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("排序")
        .help("按点赞或收藏排序，找这个博主的爆款。")
    }

    private func dateEndRow(_ title: String, on: Binding<Bool>, text: Binding<String>) -> some View {
        CreatorDateFilterControl(title: title, enabled: on, value: text)
            .frame(maxWidth: .infinity)
            .help("可单独启用起止日期；关闭保留所选日期，点击日期可直接选择并启用。")
    }

    private func thresholdRow(title: String, on: Binding<Bool>, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: on)
                .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
                .frame(width: 62, alignment: .leading)
                .qqControlMotion(tint: QQTheme.cyan)
            TextField("例如 1.5", text: text)
                .textFieldStyle(ShiyingGlassFieldStyle())
                .frame(minWidth: 68, maxWidth: .infinity)
                .qqControlMotion(tint: QQTheme.cyan).disabled(!on.wrappedValue)
                .accessibilityLabel(title + "门槛（万）")
            Text("万").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help("严格大于填写值，关闭或留空表示不限。")
    }

    private var folderCard: some View {
        QQDepthSurface(radius: 18, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("03", "保存位置", subtitle: "选择已有收集文件夹，或按主题创建新的文件夹。")
                fieldRow("目标文件夹") { folderPicker }
                fieldRow("新建文件夹") {
                    HStack(spacing: 10) { nameField; createFolderButton }
                }
                fieldRow("保存目录") {
                    HStack(spacing: 10) {
                        pathLine(batch.selectedCollection?.path ?? batch.parentFolder)
                        parentFolderButton
                    }
                }
            }
        }
    }

    private var exportCard: some View {
        QQDepthSurface(radius: 18, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("04", "导出设置", subtitle: "入队时记录画质与音轨设置，保持视频原比例。")
                fieldRow("视频画质") {
                    HStack(spacing: 10) {
                        ForEach(Quality.allCases) { option in qualityButton(option) }
                    }
                }
                fieldRow("配套音轨") {
                    HStack(spacing: 12) {
                        audioToggle
                        Text("视频保存后，本地导出同名 M4A。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var nameField: some View {
        TextField("新文件夹名称", text: $batch.newCollectionName)
            .textFieldStyle(ShiyingGlassFieldStyle())
            .qqControlMotion(tint: QQTheme.cyan)
    }

    @ViewBuilder private var folderPicker: some View {
        if batch.collections.isEmpty {
            Text("还没有收集文件夹")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
        } else {
            ShiyingGlassMenu(title: "收集文件夹", selection: collectionSelection,
                values: batch.collections.map(\.id), display: { id in batch.collections.first { $0.id == id }?.name ?? "" })
                .frame(maxWidth: .infinity)

        }
    }

    private var createFolderButton: some View {
        Button { batch.createCollection() } label: {
            Label("创建文件夹", systemImage: "plus.rectangle.on.folder")
        }
        .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
        .disabled(batch.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || batch.isRunning)
    }

    private var parentFolderButton: some View {
        Button { batch.chooseParentFolder() } label: {
            Label("选择父目录", systemImage: "folder.badge.plus")
        }
        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
    }

    private var audioToggle: some View {
        Toggle(isOn: $batch.includeAudio) {
            Text("导出 M4A").font(.system(size: 12, weight: .medium))
        }
        .toggleStyle(.switch)
        .fixedSize()
        .qqControlMotion(tint: QQTheme.cyan)
    }

    @ViewBuilder private func qualityButton(_ option: Quality) -> some View {
        if batch.quality == option {
            Button { batch.quality = option } label: {
                Text(option.title).frame(maxWidth: .infinity)
            }
            .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
            .help(option.detail)
        } else {
            Button { batch.quality = option } label: {
                Text(option.title).frame(maxWidth: .infinity)
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            .help(option.detail)
        }
    }

    private var collectionSelection: Binding<UUID> {
        Binding(
            get: { batch.selectedCollectionID ?? batch.collections.first?.id ?? UUID() },
            set: { batch.selectCollection($0) }
        )
    }

    private var results: some View {
        QQDepthSurface(radius: 18, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("05", "采集结果", subtitle: "勾选需要保存的视频，下载当前筛选下的已选结果。")
                HStack(spacing: 14) {
                    Text("符合 \(creator.filteredPosts.count)").foregroundStyle(.primary)
                    Text("已选 \(creator.selectedPosts.count)")
                    Text("未知字段 \(creator.unknownFieldCount)")
                        .foregroundStyle(creator.unknownFieldCount > 0 ? QQTheme.amber : .secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 10) {
                    Button("全选当前结果") { creator.selectAllFiltered() }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
                        .disabled(creator.filteredPosts.isEmpty)
                    Button("取消全选") { creator.clearSelection() }
                        .buttonStyle(QQSoftButtonStyle(tint: QQTheme.slate))
                        .disabled(creator.selectedIDs.isEmpty)
                }
                if creator.filteredPosts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(QQTheme.cyan.opacity(0.65))
                        Text(emptyResultText).font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .shiyingGlass(radius: 12, inset: true)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(creator.filteredPosts) { post in row(post) }
                    }
                }
            }
        }
    }

    private var emptyResultText: String {
        if !scanTouched && !creator.isScanning { return "扫描主页后，符合筛选的视频会出现在这里。" }
        if creator.isScanning && creator.posts.isEmpty { return "正在等第一页结果。" }
        if let filterIssue { return filterIssue }
        return "没有符合当前筛选的视频。"
    }

    private func row(_ post: CreatorPost) -> some View {
        let selected = creator.selectedIDs.contains(post.id)
        return Button {
            creator.toggleSelection(post.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? QQTheme.mint : Color.secondary.opacity(0.7))
                cover(post)
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.title.isEmpty ? "未命名" : post.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(post.author.isEmpty ? "作者未知" : post.author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if post.isCoauthored == true { Text("参与共创").foregroundStyle(QQTheme.cyan) }
                        Text(CreatorRowText.day(post.createdAt))
                        metric("点赞", post.diggCount)
                        metric("收藏", post.collectCount)
                        if !post.isVideo {
                            Text("非视频").font(.system(size: 10, weight: .semibold)).foregroundStyle(QQTheme.orange)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .shiyingGlass(radius: 12, inset: true)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? QQTheme.mint.opacity(0.7) : palette.hairline, lineWidth: selected ? 1.2 : 0.8)
            }
        }
        .buttonStyle(QQGhostPressStyle(tint: QQTheme.mint, radius: 12))
        .help(post.link)
        .accessibilityLabel("\(selected ? "已选" : "未选") \(post.title)")
    }

    private func metric(_ title: String, _ value: Int64?) -> some View {
        Text("\(title) \(CreatorRowText.count(value))")
            .foregroundStyle(value == nil ? Color.secondary : QQTheme.amber)
    }

    @ViewBuilder private func cover(_ post: CreatorPost) -> some View {
        let url = post.cover.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    palette.inset
                    Image(systemName: "film").foregroundStyle(QQTheme.cyan)
                }
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var ctaBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = batch.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QQTheme.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = batch.notice, !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    ctaCopy
                    ctaButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    ctaCopy
                    ctaButtons
                }
            }
        }
        .padding(14)
        .shiyingGlass(radius: 22)
    }

    private var ctaCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(targetLine)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let ctaBlock {
                Text(ctaBlock)
                    .font(.system(size: 11))
                    .foregroundStyle(QQTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ctaButtons: some View {
        HStack(spacing: 8) {
            Button {
                enqueue(startImmediately: false)
            } label: {
                Label("只加入队列", systemImage: "text.badge.plus")
            }
            .buttonStyle(QQSoftButtonStyle(tint: QQTheme.cyan))
            .disabled(ctaBlock != nil)
            Button {
                enqueue(startImmediately: true)
            } label: {
                Label("下载筛选结果", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(QQDepthButtonStyle(gradient: QQTheme.brand, tint: QQTheme.cyan, compact: true))
            .disabled(ctaBlock != nil)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var targetLine: String {
        let folder = batch.selectedCollection?.name ?? "未选择文件夹"
        let audio = batch.includeAudio ? "含音轨" : "不含音轨"
        return "\(folder) · \(batch.quality.title) · \(audio)"
    }

    private var ctaBlock: String? {
        if creator.isScanning { return "正在扫描，先不要把目前这半份结果当作全部下载。" }
        if likesOn, let likesError { return likesError }
        if collectsOn, let collectsError { return collectsError }
        if let filterIssue { return filterIssue }
        if creator.filteredPosts.isEmpty {
            if !scanTouched { return "先扫描主页。当前没有可下载的结果。" }
            return "没有符合当前筛选的视频。"
        }
        if creator.selectedPosts.isEmpty { return "还没有勾选可下载的视频。" }
        if store.busy { return "单条下载进行中，队列暂时不能接收。" }
        if batch.isRunning { return "批量队列正在运行。" }
        if batch.selectedCollection == nil { return "先选择或创建一个收集文件夹。" }
        return nil
    }

    private var filterIssue: String? {
        if let text = CreatorCore.validate(creator.filter)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let stored = creator.filterError?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        return nil
    }

    private var scanTouched: Bool {
        !creator.creatorName.isEmpty
            || creator.pageCount > 0
            || creator.scannedCount > 0
            || !creator.posts.isEmpty
            || creator.error != nil
            || creator.nextCursor != nil
            || !creator.detail.isEmpty
    }

    private var scanStatLine: String {
        if creator.shareResolved { return "\(creator.scannedCount) 条分享视频" }
        let base = "\(creator.pageCount) 页 · \(creator.scannedCount) 条作品"
        let skipped = creator.skippedNonVideoCount
        if skipped > 0 {
            return "\(base) · 跳过 \(skipped) 条非视频"
        }
        return base
    }

    private var completeness: String {
        if creator.shareResolved { return "分享解析完成" }
        if creator.needsLogin { return "需要登录补采" }
        if creator.isScanning { return "仅采到部分" }
        if scanTouched && creator.scanComplete { return "全部采完" }
        if scanTouched { return "仅采到部分" }
        return "未扫描"
    }

    private var completenessTint: Color {
        if creator.shareResolved { return QQTheme.mint }
        if creator.isScanning || (scanTouched && !creator.scanComplete) { return QQTheme.amber }
        if scanTouched && creator.scanComplete { return QQTheme.mint }
        return .secondary
    }

    private var completenessSymbol: String {
        if creator.shareResolved { return "checkmark.circle" }
        if creator.isScanning { return "dot.radiowaves.left.and.right" }
        if scanTouched && creator.scanComplete { return "checkmark.circle" }
        if scanTouched { return "exclamationmark.triangle" }
        return "circle"
    }

    private func pathLine(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pasteHome() {
        guard let value = NSPasteboard.general.string(forType: .string),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteNote = "剪贴板里没有文本。"
            return
        }
        creator.urlText = value
        pasteNote = nil
    }

    private func enqueue(startImmediately: Bool) {
        guard ctaBlock == nil else { return }
        batch.enqueueCreatorPosts(
            creator.selectedPosts,
            sourceURL: creator.sourceURL,
            singleBusy: store.busy,
            startImmediately: startImmediately)
    }

    private func hydrate() {
        guard !hydrated else { return }
        hydrated = true
        let filter = creator.filter
        fromOn = filter.fromDay != nil
        toOn = filter.toDay != nil
        fromText = filter.fromDay ?? ""
        toText = filter.toDay ?? ""
        if let likes = filter.likesAbove {
            likesOn = true
            likesText = Self.wanDraft(likes)
        }
        if let collects = filter.collectsAbove {
            collectsOn = true
            collectsText = Self.wanDraft(collects)
        }
    }

    /// 只把已有整数填回输入框。门槛仍以 CreatorCore.parseWanThreshold 为准。
    private static func wanDraft(_ value: Int64) -> String {
        guard value >= 0 else { return String(value) }
        let whole = value / 10_000
        let fraction = value % 10_000
        if fraction == 0 { return String(whole) }
        var digits = String(format: "%04d", Int(fraction))
        while digits.last == "0" { digits.removeLast() }
        return "\(whole).\(digits)"
    }

    private func pushDates() {
        var filter = creator.filter
        if fromOn {
            let from = fromText.trimmingCharacters(in: .whitespacesAndNewlines)
            filter.fromDay = from.isEmpty ? nil : from
        } else {
            filter.fromDay = nil
        }
        if toOn {
            let to = toText.trimmingCharacters(in: .whitespacesAndNewlines)
            filter.toDay = to.isEmpty ? nil : to
        } else {
            filter.toDay = nil
        }
        creator.filter = filter
    }

    private func pushThresholds() {
        var filter = creator.filter
        if likesOn {
            do {
                filter.likesAbove = try CreatorCore.parseWanThreshold(likesText)
                likesError = nil
            } catch {
                likesError = thresholdMessage(error)
            }
        } else {
            filter.likesAbove = nil
            likesError = nil
        }
        if collectsOn {
            do {
                filter.collectsAbove = try CreatorCore.parseWanThreshold(collectsText)
                collectsError = nil
            } catch {
                collectsError = thresholdMessage(error)
            }
        } else {
            filter.collectsAbove = nil
            collectsError = nil
        }
        creator.filter = filter
    }

    private func thresholdMessage(_ error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "门槛格式无效，下载已停用。" }
        return text
    }

    private var fromToggle: Binding<Bool> {
        Binding(get: { fromOn }, set: { fromOn = $0; pushDates() })
    }

    private var toToggle: Binding<Bool> {
        Binding(get: { toOn }, set: { toOn = $0; pushDates() })
    }

    private var fromBinding: Binding<String> {
        Binding(get: { fromText }, set: { fromText = $0; pushDates() })
    }

    private var toBinding: Binding<String> {
        Binding(get: { toText }, set: { toText = $0; pushDates() })
    }

    private var likesToggle: Binding<Bool> {
        Binding(get: { likesOn }, set: { likesOn = $0; pushThresholds() })
    }

    private var likesBinding: Binding<String> {
        Binding(get: { likesText }, set: { likesText = $0; pushThresholds() })
    }

    private var collectsToggle: Binding<Bool> {
        Binding(get: { collectsOn }, set: { collectsOn = $0; pushThresholds() })
    }

    private var collectsBinding: Binding<String> {
        Binding(get: { collectsText }, set: { collectsText = $0; pushThresholds() })
    }

    private var keywordBinding: Binding<String> {
        Binding(
            get: { creator.filter.keyword },
            set: { text in
                var filter = creator.filter
                filter.keyword = text
                creator.filter = filter
            }
        )
    }

    private var sortBinding: Binding<String> {
        Binding(
            get: { creator.filter.sort.rawValue },
            set: { raw in
                guard let sort = CreatorSort(rawValue: raw) else { return }
                var filter = creator.filter
                filter.sort = sort
                creator.filter = filter
            }
        )
    }

    private func sortTitle(_ raw: String) -> String {
        switch raw {
        case "latest": return "最新"
        case "likes": return "点赞"
        case "collects": return "收藏"
        default: return raw
        }
    }
}

private enum CreatorRowText {
    static func day(_ epoch: Int64?) -> String {
        guard let epoch, let zone = TimeZone(identifier: "Asia/Shanghai") else { return "日期未知" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// 标题在左、操作在右。理想宽度是两者相加，所以 ViewThatFits 能判断这一行放不放得下。
/// 放得下时多出来的空间留在中间；操作始终按理想宽度摆放，不压缩按钮文字。
private struct CreatorTitleActionLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let pieces = measured(subviews)
        let idealWidth = pieces.title.width + spacing + pieces.actions.width
        let height = max(pieces.title.height, pieces.actions.height)
        guard let limit = proposal.width, limit.isFinite else {
            return CGSize(width: idealWidth, height: height)
        }
        if idealWidth <= limit + 0.5 {
            return CGSize(width: limit, height: height)
        }
        return CGSize(width: idealWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            guard let only = subviews.first else { return }
            let size = only.sizeThatFits(.unspecified)
            only.place(at: bounds.origin, proposal: ProposedViewSize(width: size.width, height: size.height))
            return
        }
        let pieces = measured(subviews)
        let actionsWidth = min(pieces.actions.width, max(0, bounds.width))
        let titleWidth = min(pieces.title.width, max(0, bounds.width - spacing - actionsWidth))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY - pieces.title.height / 2),
            proposal: ProposedViewSize(width: titleWidth, height: pieces.title.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - actionsWidth, y: bounds.midY - pieces.actions.height / 2),
            proposal: ProposedViewSize(width: actionsWidth, height: pieces.actions.height)
        )
    }

    private func measured(_ subviews: Subviews) -> (title: CGSize, actions: CGSize) {
        let title = subviews.count > 0 ? subviews[0].sizeThatFits(.unspecified) : .zero
        let actions = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
        return (title, actions)
    }
}
