//
//  IPAPreviewPanelView.swift
//  EasySign
//

import SwiftUI

struct IPAPreviewPanelView: View {
    let info: IPAPreviewInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewSection("基础信息") {
                        previewRow("文件", info.fileName)
                        previewRow("App 目录", info.appDirectoryName)
                        previewRow("Bundle ID", info.bundleIdentifier)
                        previewRow("版本", info.versionDescription)
                        previewRow("最低系统", info.minimumOSVersion ?? "-")
                        previewRow("可执行文件", info.executableName ?? "-")
                    }

                    if let profile = info.provisioningProfile {
                        previewSection("描述文件") {
                            previewRow("名称", profile.name)
                            previewRow("UUID", profile.uuid)
                            previewRow("Team ID", profile.teamIdentifier)
                            previewRow("App ID", profile.applicationIdentifier)
                            previewRow("过期时间", profile.expirationDate?.formatString(format: "yyyy-MM-dd HH:mm:ss") ?? "-")
                        }
                    }

                    previewListSection("App Extension", values: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name)  \($0.bundleIdentifier)" })
                    previewListSection("Frameworks", values: info.frameworks)
                    previewListSection("动态库", values: info.dynamicLibraries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(info.appName.isEmpty ? info.fileName : info.appName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconData = info.iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewListSection(_ title: String, values: [String]) -> some View {
        previewSection(title) {
            if values.isEmpty {
                Text("无")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
            Text(value.isEmpty ? "-" : value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
