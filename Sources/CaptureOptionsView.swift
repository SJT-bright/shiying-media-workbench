import SwiftUI

struct CaptureOptionsView: View {
    @Binding var video: Bool
    @Binding var cover: Bool
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                Toggle("采集视频", isOn: $video)
                    .accessibilityIdentifier("capture.video")
                Toggle("采集封面", isOn: $cover)
                    .accessibilityIdentifier("capture.cover")
            }
            .toggleStyle(.checkbox)
            .disabled(disabled)
            if !video && !cover {
                Text("请至少选择一项采集内容。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if cover {
                Text("封面先临时下载，可右键复制；确认后保存，取消后清理。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
