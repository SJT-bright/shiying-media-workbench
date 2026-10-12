import Foundation

@main struct VideoCardContentChecks {
    static func main() throws {
        let content = VideoCardContent(title: "夜晚 #Claude #opus5.5", description: "夜晚 #Claude #opus5.5 \n第一段介绍。\n第二段介绍。 #历史 #知识 #光 #夜晚 #第六个")
        precondition(content.title == "夜晚")
        precondition(content.description == "第一段介绍。\n第二段介绍。")
        precondition(content.tags == ["Claude", "opus5.5", "历史", "知识", "光"])
        let adjacent = VideoCardContent(title: "作品#标签一#标签二", description: "不同的简介 #标签二 ＃标签三 #TAG #tag")
        precondition(adjacent.title == "作品")
        precondition(adjacent.description == "不同的简介")
        precondition(adjacent.tags == ["标签二", "标签三", "TAG", "标签一"])
        let titleOnly = VideoCardContent(title: "原有作品 #标签", description: nil)
        precondition(titleOnly.description.isEmpty && titleOnly.tags == ["标签"])
        let repeated = VideoCardContent(title: "同一标题", description: "同一标题")
        precondition(repeated.description.isEmpty)
        let separate = VideoCardContent(title: "标题", description: "标题里的不同内容\n下一段")
        precondition(separate.description == "标题里的不同内容\n下一段")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let library = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let items = library["items"] as! [[String: Any]]
            var rows: [[String: Any]] = []
            for item in items where item["status"] as? String == "completed" {
                let rawTitle = item["title"] as? String ?? ""
                let rawDescription = item["description"] as? String
                let result = VideoCardContent(title: rawTitle, description: rawDescription)
                precondition(!result.title.contains("\n") && result.tags.count <= 5)
                rows.append(["id": item["id"]!, "title": result.title, "description": result.description, "tags": result.tags])
            }
            print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        }
        print("Video card metadata checks passed")
    }
}
