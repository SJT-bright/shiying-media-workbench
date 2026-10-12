import Foundation

@main struct PlatformBridgeChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/multiplatform-20261006/bridge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        BatchStore.dataRootOverride = root
        CreatorStore.sessionFileOverride = root.appendingPathComponent("creator-session.json")
        let store = BatchStore()
        store.newCollectionName = "跨平台资料"
        store.createCollection()
        var checks = 0
        func check(_ name: String, _ ok: Bool) {
            precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name)
        }
        func post(_ id: String, _ link: String, _ platform: String) -> CreatorPost {
            CreatorPost(id: id, link: link, title: "真实来源快照", author: "博主",
                        createdAt: nil, diggCount: nil, collectCount: nil, cover: nil,
                        isVideo: true, platformRaw: platform)
        }
        let bv = post("BV13x41117TL", "https://www.bilibili.com/video/BV13x41117TL", "bilibili")
        let xhs = post("6381a8c0000000001f00c4ae", "https://www.xiaohongshu.com/explore/6381a8c0000000001f00c4ae?xsec_token=abc%2Bdef&xsec_source=pc_feed", "xiaohongshu")
        var wx = post("web-real", "https://channels.weixin.qq.com/platform#shiying-capture-web-real", "wechat")
        wx.mediaURL = "https://finder.video.qq.com/media.mp4?signed=PRIVATE_CAPTURE"
        let dy = post("7000000000000000001", "https://www.douyin.com/video/7000000000000000001", "douyin")
        check("四平台同时入现有队列", store.enqueueCreatorPosts([dy,bv,xhs,wx], sourceURL: "官方扫描来源", singleBusy: false, startImmediately: false) == 4)
        check("入队不自动联网", !store.isRunning && !store.hasLiveChild)
        check("平台来源不拼成抖音", store.items.map(\.link).contains(bv.link) && store.items.last?.link == wx.link)
        check("记录平台身份", Set(store.items.compactMap(\.platformRaw)) == Set(["douyin","bilibili","xiaohongshu","wechat"]))
        check("小红书编码签名保留", store.items.first { $0.platformRaw == "xiaohongshu" }?.link.contains("abc%2Bdef") == true)
        check("按平台作品去重", store.enqueueCreatorPosts([dy,bv,xhs,wx], sourceURL: "官方扫描来源", singleBusy: false, startImmediately: false) == 0 && store.items.count == 4)
        let file = root.appendingPathComponent("batch/batch-library.json")
        let data = try Data(contentsOf: file)
        check("短效媒体令牌不进入普通资料库", !String(decoding: data, as: UTF8.self).contains("PRIVATE_CAPTURE"))
        let restored = BatchStore()
        check("重新打开保留四平台待处理", restored.items.count == 4 && restored.items.allSatisfy { $0.status == .pending })
        var mismatch = bv; mismatch.platformRaw = "douyin"
        check("错配平台拒绝", restored.enqueueCreatorPosts([mismatch], sourceURL: "来源", singleBusy: false, startImmediately: false) == 0)
        var wrongID = bv; wrongID.id = "BV13x411XXXX"
        check("错配作品拒绝", restored.enqueueCreatorPosts([wrongID], sourceURL: "来源", singleBusy: false, startImmediately: false) == 0)
        check("单下载忙时拒绝批量", restored.enqueueCreatorPosts([bv], sourceURL: "来源", singleBusy: true, startImmediately: false) == 0)
        check("旧资料库字段仍可读取", try BatchRepository(rootURL: root.appendingPathComponent("batch")).load().items.count == 4)
        let wxShare = post("official-feed-id", "https://weixin.qq.com/sph/ShareCode#shiying-capture-official-feed-id", "wechat")
        check("视频号分享解析结果可加入队列", restored.enqueueCreatorPosts([wxShare], sourceURL: "https://weixin.qq.com/sph/ShareCode", singleBusy: false, startImmediately: false) == 1)
        check("视频号分享编号去重", restored.enqueueCreatorPosts([wxShare], sourceURL: "https://weixin.qq.com/sph/ShareCode", singleBusy: false, startImmediately: false) == 0)
        print("PlatformBridgeChecks: \(checks) passed")
    }
}
