import SwiftUI

struct UpdateView: View {
    @ObservedObject var service: UpdateService
    let update: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 28)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本 \(update.version)").font(.headline)
                    Text("当前 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                Text(update.releaseNotes.isEmpty ? "(无更新说明)" : update.releaseNotes)
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8).background(.quaternary.opacity(0.4)).cornerRadius(8)

            if let p = service.downloadProgress {
                ProgressView(value: p) { Text("下载中… \(Int(p * 100))%").font(.caption) }
                HStack { Spacer(); Button("取消") { service.cancelDownload() } }
            } else {
                Text("未签名分发:下载后若提示「已损坏」,右键打开,或终端执行 xattr -dr com.apple.quarantine /Applications/EasySign.app")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("以后再说") { service.dismissUpdate() }
                    Spacer()
                    Button("下载更新") { service.startDownload() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
