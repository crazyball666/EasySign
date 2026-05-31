//
//  PreviewViewController.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let stackView = NSStackView()

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        contentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 18
        stackView.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)

        contentView.addSubview(stackView)
        scrollView.documentView = contentView
        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        view = rootView
        preferredContentSize = NSSize(width: 680, height: 760)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let info = try IPAPreviewService().preview(url: url)
        let title = info.appName.isEmpty ? info.fileName : info.appName

        await MainActor.run {
            self.title = title
            self.preferredContentSize = NSSize(width: 680, height: 760)
            self.render(info: info)
        }
    }
}

private extension PreviewViewController {
    func render(info: IPAPreviewInfo) {
        stackView.arrangedSubviews.forEach { subview in
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        stackView.addArrangedSubview(headerView(info: info))
        stackView.addArrangedSubview(sectionView(title: "基础信息", rows: [
            ("文件", info.fileName),
            ("App 目录", info.appDirectoryName),
            ("Bundle ID", info.bundleIdentifier),
            ("版本", info.versionDescription),
            ("最低系统", info.minimumOSVersion ?? "-"),
            ("可执行文件", info.executableName ?? "-")
        ]))
        stackView.addArrangedSubview(sectionView(title: "签名信息", rows: [
            ("签名状态", info.signingDescription),
            ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
        ]))
        stackView.addArrangedSubview(provisioningSection(info.provisioningProfile))
        stackView.addArrangedSubview(listSection(title: "App Extension", values: info.appexes.map {
            "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name)  \($0.bundleIdentifier)"
        }))
        stackView.addArrangedSubview(listSection(title: "Frameworks", values: info.frameworks))
        stackView.addArrangedSubview(listSection(title: "动态库", values: info.dynamicLibraries))
    }

    func headerView(info: IPAPreviewInfo) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 16
        iconView.layer?.masksToBounds = true
        iconView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        iconView.image = info.iconData.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72)
        ])

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.addArrangedSubview(label(
            info.appName.isEmpty ? info.fileName : info.appName,
            font: .systemFont(ofSize: 24, weight: .semibold),
            color: .labelColor
        ))
        textStack.addArrangedSubview(label(
            info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier,
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor
        ))

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(textStack)
        return row
    }

    func provisioningSection(_ profile: IPAPreviewProvisioningProfile?) -> NSView {
        guard let profile else {
            return sectionView(title: "描述文件", rows: [("状态", "未内嵌描述文件")])
        }

        let rows: [(String, String)] = [
            ("名称", profile.name),
            ("类型", profile.profileType),
            ("UUID", profile.uuid),
            ("Team Name", profile.teamName),
            ("Team ID", profile.teamIdentifier),
            ("App ID", profile.applicationIdentifier),
            ("创建时间", format(profile.creationDate)),
            ("过期时间", format(profile.expirationDate)),
            ("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)"),
            ("APS", profile.apsEnvironment ?? "-"),
            ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.addArrangedSubview(sectionView(title: "描述文件", rows: rows))
        stack.addArrangedSubview(listSection(title: "签名证书", values: profile.certificates.map(certificateDescription)))
        stack.addArrangedSubview(listSection(title: "Entitlements", values: profile.entitlementKeys))
        return stack
    }

    func sectionView(title: String, rows: [(String, String)]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 8
        container.addArrangedSubview(separator())
        container.addArrangedSubview(label(title, font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor))

        for row in rows {
            container.addArrangedSubview(rowView(name: row.0, value: row.1.isEmpty ? "-" : row.1))
        }

        return container
    }

    func listSection(title: String, values: [String]) -> NSView {
        let rows = values.isEmpty ? [(" ", "无")] : values.map { (" ", $0) }
        return sectionView(title: title, rows: rows)
    }

    func rowView(name: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14

        let nameLabel = label(name, font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        nameLabel.alignment = .right
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let valueLabel = label(value, font: .systemFont(ofSize: 13), color: .labelColor)
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let textField = NSTextField(labelWithString: text)
        textField.font = font
        textField.textColor = color
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.isSelectable = true
        return textField
    }

    func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    func certificateDescription(_ certificate: IPAPreviewCertificate) -> String {
        var parts = [certificate.commonName]
        if !certificate.teamIdentifier.isEmpty {
            parts.append("Team ID: \(certificate.teamIdentifier)")
        }
        if let notAfter = certificate.notAfter {
            parts.append("过期: \(format(notAfter))")
        }
        if !certificate.sha1Fingerprint.isEmpty {
            parts.append("SHA1: \(certificate.sha1Fingerprint)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
    }

    func format(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
