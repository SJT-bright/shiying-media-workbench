import Foundation

// Foundation-only, no network and no data writes.
// swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
//   Sources/BatchCore.swift Sources/SingleLinkParser.swift Tests/SingleLinkParserChecks.swift \
//   -o build/multi-download-20261013/parser-checks

@main
struct SingleLinkParserChecks {
    static var passed = 0
    static var failures: [String] = []

    static func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1 }
        else { failures.append(name) }
    }

    static func expectError(_ name: String, _ expected: SingleLinkParseError, _ text: String) {
        do {
            _ = try SingleLinkParser.parse(text)
            failures.append("\(name): 没有拒绝输入")
        } catch let error as SingleLinkParseError {
            check(name, error == expected)
        } catch {
            failures.append("\(name): \(error)")
        }
    }

    static func main() throws {
        let first = "https://weixin.qq.com/sph/AtNcHSYgoJ"
        let second = "https://weixin.qq.com/sph/AJd2nt0rGG"
        let third = "https://weixin.qq.com/sph/AMoWcRl7SH"
        let douyin = "https://www.douyin.com/video/7000000000000000001"
        let short = "https://v.douyin.com/AbCdE/"
        let bilibili = "https://www.bilibili.com/video/BV13x41117TL"
        let xhs = "https://www.xiaohongshu.com/explore/6381a8c0000000001f00c4ae"

        let ten = (0..<10).map { "https://weixin.qq.com/sph/test-\($0)" }
        let tenResult = try SingleLinkParser.parse(ten.joined(separator: "\n"))
        check("10 条分享全部读取并保留顺序", tenResult.links == ten)
        check("10 条无重复", tenResult.duplicateCount == 0)
        check("10 条无拒绝", tenResult.unsupportedCount == 0)

        let sameRow = try SingleLinkParser.parse("第一条 \(first) 第二条 \(second) \(third)")
        check("同一行三条完整读取", sameRow.links == [first, second, third])
        let crlf = try SingleLinkParser.parse("\r\n\(first)\r\n\(second)\r\n\r\n\(third)\r\n")
        check("CRLF 空行不影响顺序", crlf.links == [first, second, third])
        let punctuated = try SingleLinkParser.parse("分享：『\(first)』，\(second)；【\(third)】。")
        check("无空格全角标点分隔可提取", punctuated.links == [first, second, third])
        let quoted = try SingleLinkParser.parse("<\(first)> ‘\(second)’ (\(third)),")
        check("包围标点和英文尾标点剥离", quoted.links == [first, second, third])
        let escaped = try SingleLinkParser.parse("复制打开 https\\://v.douyin.com/AbCdE/ ，\(first)")
        check("转义冒号兼容", escaped.links == [short, first])
        let upper = try SingleLinkParser.parse("HTTPS://WEIXIN.QQ.COM/sph/AtNcHSYgoJ")
        check("协议和域名大小写兼容", upper.links == [first])

        let duplicate = try SingleLinkParser.parse("\(first)\n\(second)\n\(second)\n\(third)\n\(first)")
        check("重复链接保留首次位置", duplicate.links == [first, second, third])
        check("每个额外重复均计数", duplicate.duplicateCount == 2)
        let normalizedDuplicate = try SingleLinkParser.parse("\(douyin)?tracking=1\nhttps://douyin.com/note/7000000000000000001")
        check("既有作品规范化兼容", normalizedDuplicate.links == [douyin])
        check("规范化重复计数", normalizedDuplicate.duplicateCount == 1)

        let four = try SingleLinkParser.parse("\(douyin)\n\(bilibili)\n\(xhs)\n\(first)")
        check("四平台混合顺序保持", four.links == [douyin, bilibili, xhs, first])
        let allHosts = [
            "https://v.douyin.com/AbCdE/", "https://www.douyin.com/video/7000000000000000001",
            "https://douyin.com/video/7000000000000000002", "https://www.iesdouyin.com/share/video/7000000000000000003/",
            "https://iesdouyin.com/share/video/7000000000000000004/", "https://www.bilibili.com/video/BV13x41117TL",
            "https://bilibili.com/video/av42", "https://b23.tv/AbCdE/", "https://www.xiaohongshu.com/explore/6381a8c0000000001f00c4ae",
            "https://xiaohongshu.com/discovery/item/6381a8c0000000001f00c4af", "https://xhslink.com/AbCdE",
            "https://www.xhslink.com/AbCdE", "https://channels.weixin.qq.com/platform#shiying-capture-test",
            "https://weixin.qq.com/sph/test-a", "https://www.weixin.qq.com/sph/test-b"
        ]
        let hostsResult = try SingleLinkParser.parse(allHosts.joined(separator: "\n"))
        check("可用官方作品主机全部接受", hostsResult.links.count == allHosts.count && hostsResult.unsupportedCount == 0)

        let signed = xhs + "?xsec_token=abc%2Bdef&xsec_source=pc_feed&tracking=1"
        let signedResult = try SingleLinkParser.parse(signed)
        check("小红书签名保持", signedResult.links == [xhs + "?xsec_token=abc%2Bdef&xsec_source=pc_feed"])
        let wxSigned = first + "?key=abc%2Bdef&scene=2#shiying-capture-one"
        check("视频号查询和捕获片段保持", try SingleLinkParser.parse(wxSigned).links == [wxSigned])
        let parts = try SingleLinkParser.parse("\(bilibili)/?p=1\n\(bilibili)/?p=2")
        check("B站不同分P不去重", parts.links == [bilibili + "?p=1", bilibili + "?p=2"])

        let refused = [
            "https://douyin.com.evil.test/video/7000000000000000001",
            "https://www.bilibili.com.evil.test/video/BV13x41117TL",
            "https://weixin.qq.com.evil.test/sph/test",
            "https://x@www.douyin.com/video/7000000000000000001",
            "https://www.douyin.com:444/video/7000000000000000001",
            "ftp://www.douyin.com/video/7000000000000000001",
            "https://youtube.com/watch?v=test",
            "https://space.bilibili.com/42",
            "https://weixin.qq.com/s/article-id",
            "https://www.xiaohongshu.com/user/profile/test"
        ]
        let mixed = try SingleLinkParser.parse("\(first) " + refused.joined(separator: " ") + " \(second)")
        check("不支持链接不吞掉有效邻项", mixed.links == [first, second])
        check("同一行全部拒绝链接逐条计数", mixed.unsupportedCount == refused.count)
        let embedded = try SingleLinkParser.parse("https://evil.test/#\(douyin)\n\(first)")
        check("不从错误主机片段提取伪造官方链接", embedded.links == [first] && embedded.unsupportedCount == 1)
        let queryEmbedded = try SingleLinkParser.parse("https://evil.test/?redirect=\(douyin)\n\(first)")
        check("不从错误主机查询提取官方链接", queryEmbedded.links == [first] && queryEmbedded.unsupportedCount == 1)
        let repeatRefused = try SingleLinkParser.parse("https://evil.test/a https://evil.test/a \(first)")
        check("重复拒绝链接每次计数", repeatRefused.unsupportedCount == 2 && repeatRefused.duplicateCount == 0)
        let prose = try SingleLinkParser.parse("10.13 复制此链接打开视频号\n\(first)\n看看这些分享吧")
        check("普通分享文案不计为拒绝链接", prose.links == [first] && prose.unsupportedCount == 0)

        let bare = try SingleLinkParser.parse("v.douyin.com/AbCdE/\n7000000000000000001\n\(first)")
        check("无协议抖音和19位ID兼容", bare.links == [short, douyin, first])
        let bareSameRow = try SingleLinkParser.parse("v.douyin.com/AbCdE/ \(first) douyin.com/video/7000000000000000001")
        check("无协议和完整链接同一行按位置排列", bareSameRow.links == [short, first, douyin])
        let bareSmuggled = try SingleLinkParser.parse("https://evil.test/?next=v.douyin.com/AbCdE/\n\(first)")
        check("无协议兼容不从恶意外层URL抽取", bareSmuggled.links == [first] && bareSmuggled.unsupportedCount == 1)

        expectError("空输入明确拒绝", .emptyInput, " \t\r\n　")
        expectError("纯文案零链接明确拒绝", .noSupportedLinks(unsupportedCount: 0), "复制这段打开看看")
        expectError("全不支持链接给出数量", .noSupportedLinks(unsupportedCount: refused.count), refused.joined(separator: "\r\n"))
        expectError("非ASCII19位数不当作品ID", .noSupportedLinks(unsupportedCount: 0), "７０００００００００００００００００１")

        let twoHundred = (0..<200).map { "https://weixin.qq.com/sph/limit-\($0)" }
        let boundary = try SingleLinkParser.parse(twoHundred.joined(separator: "\n"))
        check("200 条边界全量接受", boundary.links == twoHundred)
        let duplicateBoundary = try SingleLinkParser.parse((twoHundred + [twoHundred[0], twoHundred[199]]).joined(separator: "\n"))
        check("200条加重复不误判超量", duplicateBoundary.links == twoHundred && duplicateBoundary.duplicateCount == 2)
        let over = (0..<205).map { "https://weixin.qq.com/sph/over-\($0)" }.joined(separator: "\n")
        expectError("205条拒绝不返回前200且准确计数", .tooManyLinks(count: 205, limit: 200), over)

        let padded = first + String(repeating: " ", count: SingleLinkParser.maxTextBytes - first.utf8.count)
        check("5MiB字节边界接受", try SingleLinkParser.parse(padded).links == [first])
        expectError("超过5MiB一字节拒绝", .textTooLarge(utf8Bytes: SingleLinkParser.maxTextBytes + 1, limit: SingleLinkParser.maxTextBytes), padded + " ")
        let multiByte = first + String(repeating: "字", count: (SingleLinkParser.maxTextBytes / 3) + 1)
        expectError("UTF8按字节检查中文超量", .textTooLarge(utf8Bytes: multiByte.utf8.count, limit: SingleLinkParser.maxTextBytes), multiByte)

        if failures.isEmpty {
            print("SingleLinkParserChecks: \(passed) 项通过；全程离线且不写资料库。")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            print("SingleLinkParserChecks: \(passed) 项通过，\(failures.count) 项失败。")
            exit(1)
        }
    }
}
