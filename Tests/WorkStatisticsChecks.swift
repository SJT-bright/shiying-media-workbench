import Foundation
@main struct WorkStatisticsChecks {
 @MainActor static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("shiying-statistics-" + UUID().uuidString)
  defer { WorkStatisticsStore.dataRootOverride = nil; WorkStatisticsStore.workerOverrideURL = nil; CreatorStore.sessionFileOverride = nil; CreatorStore.sessionCookieReaderOverride = nil; try? FileManager.default.removeItem(at: root) }
  WorkStatisticsStore.dataRootOverride = root
  CreatorStore.sessionFileOverride = root.appendingPathComponent("synthetic-session.json")
  WorkStatisticsStore.workerOverrideURL = root.appendingPathComponent("missing-test-worker")
  let store = WorkStatisticsStore(), id = "7000000000000000001", other = "7000000000000000002"
  var checks = 0
  func check(_ name: String, _ ok: Bool) { if !ok { FileHandle.standardError.write(Data(("FAIL " + name + "\n").utf8)) }; precondition(ok, "FAIL " + name); checks += 1; print("PASS " + name) }
  func snapshot(_ likes: Int64, _ when: Int64) -> WorkStatistics { WorkStatistics(likeCount:likes,commentCount:0,collectCount:3,viewCount:nil,viewsNote:"未公开",observedAt:when,source:"合成接口") }
  func event(_ value: WorkStatistics, _ key: String = "7000000000000000001") throws -> [String:Any] {
   ["event":"metrics_value","id":key,"statistics":try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))]
  }
  var previous = snapshot(100,1000), latest = snapshot(112,2000)
  previous.commentCount = 10; latest.commentCount = 7
  check("changes compare only known values with signed direction", latest.deltas(from: previous).map(\.amount) == [12,-3])
  latest.viewCount = 50
  check("unknown baseline never becomes fake zero change", !latest.deltas(from: previous).contains { $0.key == "view" })
  check("first observation has no fabricated delta", latest.deltas(from: nil).isEmpty)
  let huge = WorkStatisticsChange(id:id, deltas:[WorkStatisticsDelta(key:"like",oldValue:0,newValue:Int64.max),WorkStatisticsDelta(key:"comment",oldValue:0,newValue:Int64.max)])
  check("large change sorting cannot overflow", huge.impact == Int64.max)
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String:Any]
  legacy.removeValue(forKey:"coverURL")
  check("legacy statistics without cover decode", try JSONDecoder().decode(WorkStatistics.self,from:JSONSerialization.data(withJSONObject:legacy)).coverURL == nil)
  check("launch never updates automatically", !store.isUpdating && store.entries.isEmpty)
  check("canonical URL resolves identity", WorkStatisticsRepository.id(link:"https://www.douyin.com/video/"+id) == id)
  check("other platform never relabeled as Douyin", WorkStatisticsRepository.id(link:"https://www.bilibili.com/video/BV123",videoID:id) == nil)
  store.consume(try event(snapshot(100,1000)),allowed:[id])
  check("true zero comments and hidden views distinguished", store.entries[id]?.value?.commentCount == 0 && store.entries[id]?.value?.viewCount == nil)
  store.consume(["event":"metrics_failure","id":id,"message":"HTTP 403 验证失败"],allowed:[id])
  check("failure retains prior value and specific reason", store.entries[id]?.value?.likeCount == 100 && store.entries[id]?.issue?.contains("403") == true)
  store.consume(try event(snapshot(120,2000)),allowed:[id])
  check("manual update replaces value and clears prior failure", store.entries[id]?.value?.likeCount == 120 && store.entries[id]?.issue == nil)
  store.consume(try event(snapshot(90,1500)),allowed:[id])
  check("older result never overwrites newer snapshot", store.entries[id]?.value?.likeCount == 120)
  store.consume(try event(snapshot(400,3000),other),allowed:[id])
  check("unrequested work is rejected", store.entries[other] == nil)
  var invalid = snapshot(100,3000);invalid.viewCount = 0
  store.consume(try event(invalid),allowed:[id])
  check("zero placeholder is rejected by native model", store.entries[id]?.value?.observedAt == 2000)
  var post = CreatorPost(id:id,link:"https://www.douyin.com/video/"+id,title:"同一作品",author:"作者",isVideo:true)
  post.statistics = snapshot(140,4000);store.adoptScan([post])
  check("repeat homepage scan updates existing identity", store.entries.count == 1 && store.entries[id]?.value?.likeCount == 140)
  check("scan changes use stable identity and title", store.change(link:post.link,videoID:id)?.deltas.first?.amount == 20 && store.lastChanges.first?.title == "同一作品")
  let reloaded = WorkStatisticsStore()
  check("restart preserves snapshot and time", reloaded.entries[id]?.value == store.entries[id]?.value)
  var reply: (([HTTPCookie]) -> Void)?
  CreatorStore.sessionCookieReaderOverride = { reply = $0 }
  store.refresh([id]);post.statistics = snapshot(160,4500);store.adoptScan([post])
  check("concurrent scan waits for manual update", store.entries[id]?.value?.likeCount == 140)
  store.cancel()
  check("cancel before launch still adopts queued scan", store.entries[id]?.value?.likeCount == 160 && !store.isUpdating)
  store.refresh([id]);post.statistics = snapshot(180,4800);store.adoptScan([post])
  reply?([]);CreatorStore.sessionCookieReaderOverride = nil
  check("startup failure cannot hide failure or drop queued scan", store.entries[id]?.value?.likeCount == 180 && store.error?.contains("组件缺失") == true && !store.isUpdating)
  let channel = "https://weixin.qq.com/sph/ArticleSample", bili = "https://www.bilibili.com/video/BV1yraa6jERQ"
  check("source comes from link rather than folder or author", MediaSource.from(link: channel) == .wechat && MediaSource.from(link: bili) == .bilibili && MediaSource.from(link: "https://www.douyin.com/video/"+id) == .douyin)
  check("Channels has stable share identity independent of metadata ID", WorkStatisticsRepository.id(link: channel,videoID:id) == "wechat:share:ArticleSample")
  check("Bilibili parts share one platform-qualified statistics key", WorkStatisticsRepository.id(link:bili,videoID:"BV1yraa6jERQ_p1") == "bilibili:BV1yraa6jERQ")
  let wechatKey = WorkStatisticsRepository.id(link:channel)!
  var channels = snapshot(1504,5000);channels.source = "视频号官方预览";channels.collectCount = nil;channels.recommendCount = 3474;channels.commentCount = 198;channels.displayCounts = ["share":"2.1万"]
  store.consume(try event(channels,wechatKey),allowed:[wechatKey])
  check("Channels values are saved without overwriting Douyin", store.entries[wechatKey]?.value?.recommendCount == 3474 && store.entries[id]?.value?.likeCount == 180 && store.entries[wechatKey]?.value?.collectCount == nil)
  var publicZero = snapshot(0,5000);publicZero.source = "B站公开作品接口";publicZero.viewCount = 0;publicZero.viewCountIsPublic = true
  check("confirmed public zero differs from Douyin placeholder", publicZero.valid && channels.valid)
  check("restart reads original and namespaced statistics together", WorkStatisticsStore().entries[wechatKey]?.value == channels)
  let request = WorkStatisticsRepository.request(link:channel,videoID:id,homepage:"https://www.douyin.com/user/synthetic")!
  check("platform request does not borrow another platform homepage", request.platform == "wechat" && request.homepage == nil)
  let bad = Data("{合成坏JSON".utf8), file = root.appendingPathComponent("work-statistics.json")
  let priorChanges = store.lastChanges
  try bad.write(to:file);store.consume(try event(snapshot(900,5000)),allowed:[id])
  check("save failure restores displayed prior value", store.entries[id]?.value?.likeCount == 180 && store.error?.contains("保存失败") == true)
  check("failed persistence cannot publish unsaved changes", store.lastChanges == priorChanges)
  check("corrupt statistics file is not overwritten", try Data(contentsOf:file) == bad)
  check("fresh load reports corrupt file instead of empty success", WorkStatisticsStore().error != nil)
  print("WorkStatisticsChecks: \(checks) passed")
 }
}
