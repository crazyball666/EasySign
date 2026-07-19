import SwiftUI

struct UpdateView: View {
    @ObservedObject var service: UpdateService
    let update: UpdateInfo

    var body: some View {
        GlassCanvas {
            VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                WorkspaceHeader(icon: "arrow.down.circle.fill", title: "发现新版本 \(update.version)", subtitle: "当前 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")", status: updateStatus, statusTitle: updateStatusTitle)
                ReleaseNotesView(
                    notes: ReleaseNotesParser.parse(update.releaseNotes),
                    releaseURL: update.releaseURL
                )
                .frame(height: 160)
                .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingM)

            if service.readyToInstall {
                Text("已下载完成。点「安装并重启」自动覆盖更新并重新打开 EasySign。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("以后再说") { service.dismissUpdate() }
                    Spacer()
                    Button("安装并重启") { service.installAndRelaunch() }.keyboardShortcut(.defaultAction)
                }
            } else if service.installerOpened {
                Text("已下载并打开安装器。请把 EasySign 拖进「应用程序」覆盖,然后重新打开本应用。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("完成") { service.dismissUpdate() }.keyboardShortcut(.defaultAction) }
            } else if let p = service.downloadProgress {
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
            .padding(GlassMetric.spacingXL)
        }
        .frame(width: 460)
    }

    private var updateStatus: GlassStatus { service.readyToInstall ? .success : (service.downloadProgress == nil ? .idle : .active) }
    private var updateStatusTitle: String { service.readyToInstall ? "准备安装" : (service.downloadProgress == nil ? "等待下载" : "下载中") }
}

/// 更新说明的渲染。行内标记(粗体/链接/行内代码)交给 AttributedString,
/// 行级结构(标题/条目)由 ReleaseNotesParser 切好。
private struct ReleaseNotesView: View {
    @Environment(\.colorScheme) private var colorScheme
    let notes: ReleaseNotes
    let releaseURL: URL?

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        if notes.hasNoDescription {
            // 自动生成的 release 常常正文只有一行 Full Changelog 链接。与其把裸 URL
            // 铺满整块区域,不如直说没有说明,再给个去处。
            VStack(spacing: GlassMetric.spacingS) {
                Image(systemName: "text.append")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(palette.mutedText)
                Text("本次发布未附更新说明")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.mutedText)
                if let url = changelogDestination {
                    Link("查看完整更新日志", destination: url)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: GlassMetric.spacingXS) {
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
                        ForEach(Array(notes.blocks.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .heading(let text):
                                Text(inline(text))
                                    .font(.callout.weight(.semibold))
                            case .bullet(let text):
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(palette.mutedText)
                                    Text(inline(text)).font(.callout)
                                }
                            case .paragraph(let text):
                                Text(inline(text)).font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                // 固定在滚动区之外:说明一长,链接就被挤到看不见的地方了。
                if let url = changelogDestination {
                    Link("查看完整更新日志", destination: url)
                        .font(.caption)
                }
            }
        }
    }

    /// 优先用正文里的 compare 链接,没有就退回 release 页面。
    private var changelogDestination: URL? { notes.fullChangelogURL ?? releaseURL }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
