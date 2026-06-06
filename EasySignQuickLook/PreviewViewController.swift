//
//  PreviewViewController.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let contentStack = NSStackView()

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 14

        contentView.addSubview(contentStack)
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

            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -34),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        ])

        view = rootView
        preferredContentSize = NSSize(width: 760, height: 820)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let info = try IPAPreviewService().preview(url: url)
        let title = info.appName.isEmpty ? info.fileName : info.appName

        await MainActor.run {
            self.title = title
            self.preferredContentSize = NSSize(width: 760, height: 820)
            self.render(info: info)
        }
    }
}

private extension PreviewViewController {
    func render(info: IPAPreviewInfo) {
        contentStack.arrangedSubviews.forEach { subview in
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        addPreviewCard(headerCard(info: info))
        addPreviewCard(summaryGrid(info: info))
        addPreviewCard(sectionCard(title: "签名信息", rows: [
            ("状态", info.signingDescription),
            ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
        ]))
        addPreviewCard(provisioningCard(info.provisioningProfile))
        addPreviewCard(listCard(title: "组件", rows: [
            ("App Extension", info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name)  \($0.bundleIdentifier)" }),
            ("Frameworks", info.frameworks),
            ("动态库", info.dynamicLibraries)
        ]))
    }

    func addPreviewCard(_ card: NSView) {
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    func headerCard(info: IPAPreviewInfo) -> NSView {
        let card = cardContainer()
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 18
        iconView.layer?.masksToBounds = true
        iconView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        iconView.image = info.iconData.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName)

        let titleStack = NSStackView()
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 7

        titleStack.addArrangedSubview(label(
            info.appName.isEmpty ? info.fileName : info.appName,
            font: .systemFont(ofSize: 28, weight: .semibold),
            color: .labelColor
        ))
        titleStack.addArrangedSubview(label(
            info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier,
            font: .systemFont(ofSize: 14, weight: .medium),
            color: .secondaryLabelColor
        ))

        let badgeRow = NSStackView()
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY
        badgeRow.spacing = 8
        badgeRow.addArrangedSubview(badge(info.versionDescription, tint: .systemBlue))
        if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
            badgeRow.addArrangedSubview(badge("Team \(teamId)", tint: .systemGreen))
        }
        if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
            badgeRow.addArrangedSubview(badge(profileType, tint: .systemIndigo))
        }
        titleStack.addArrangedSubview(badgeRow)

        card.addSubview(iconView)
        card.addSubview(titleStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 82),
            iconView.heightAnchor.constraint(equalToConstant: 82),

            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            titleStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            titleStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleStack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 18),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 22),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: titleStack.bottomAnchor, constant: 22)
        ])

        return card
    }

    func summaryGrid(info: IPAPreviewInfo) -> NSView {
        let rows: [(String, String)] = [
            ("文件", info.fileName),
            ("App 目录", info.appDirectoryName),
            ("Bundle ID", info.bundleIdentifier),
            ("版本", info.versionDescription),
            ("最低系统", info.minimumOSVersion ?? "-"),
            ("可执行文件", info.executableName ?? "-")
        ]
        return sectionCard(title: "基础信息", rows: rows)
    }

    func provisioningCard(_ profile: IPAPreviewProvisioningProfile?) -> NSView {
        guard let profile else {
            return sectionCard(title: "描述文件", rows: [("状态", "未内嵌描述文件")])
        }

        let rows: [(String, String)] = [
            ("有效性", validityText(for: profile)),
            ("名称", profile.name),
            ("类型", profile.profileType),
            ("Team Name", profile.teamName),
            ("Team ID", profile.teamIdentifier),
            ("App ID", profile.applicationIdentifier),
            ("UUID", profile.uuid),
            ("创建时间", format(profile.creationDate)),
            ("过期时间", format(profile.expirationDate)),
            ("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)"),
            ("证书数", "\(profile.certificates.count)"),
            ("Entitlements", "\(profile.entitlementKeys.count)"),
            ("APS", profile.apsEnvironment ?? "-"),
            ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
        ]

        let card = cardContainer()
        let stack = cardStack(title: "描述文件")
        card.addSubview(stack)
        pin(stack, to: card, inset: 18)

        for row in rows {
            let value = row.1.isEmpty ? "-" : row.1
            addFullWidth(keyValueRow(row.0, value, valueColor: highlightColor(for: row.0, value: value)), to: stack)
        }
        addFullWidth(separator(), to: stack)
        addFullWidth(listBlock(title: "设备列表", values: deviceValues(profile), monospaced: true), to: stack)
        addFullWidth(listBlock(title: "签名证书", values: profile.certificates.map(certificateDescription)), to: stack)
        addFullWidth(listBlock(title: "Entitlements", values: profile.entitlementKeys, monospaced: true), to: stack)
        return card
    }

    func listCard(title: String, rows: [(String, [String])]) -> NSView {
        let card = cardContainer()
        let stack = cardStack(title: title)
        card.addSubview(stack)
        pin(stack, to: card, inset: 18)

        for row in rows {
            addFullWidth(listBlock(title: row.0, values: row.1, monospaced: row.0 != "App Extension"), to: stack)
        }

        return card
    }

    func sectionCard(title: String, rows: [(String, String)]) -> NSView {
        let card = cardContainer()
        let stack = cardStack(title: title)
        card.addSubview(stack)
        pin(stack, to: card, inset: 18)

        for row in rows {
            addFullWidth(keyValueRow(row.0, row.1.isEmpty ? "-" : row.1), to: stack)
        }

        return card
    }

    func cardContainer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
        view.layer?.shadowRadius = 8
        return view
    }

    func cardStack(title: String) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 12
        let titleLabel = label(title, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
        addFullWidth(titleLabel, to: stack)
        return stack
    }

    func keyValueRow(_ key: String, _ value: String, valueColor: NSColor? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = label(key, font: .systemFont(ofSize: 12, weight: .medium), color: .tertiaryLabelColor)
        keyLabel.maximumNumberOfLines = 1
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = label(value, font: .systemFont(ofSize: 13, weight: valueColor == nil ? .regular : .medium), color: valueColor ?? .labelColor)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(keyLabel)
        row.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            keyLabel.widthAnchor.constraint(equalToConstant: 112),

            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: row.topAnchor),

            row.bottomAnchor.constraint(greaterThanOrEqualTo: keyLabel.bottomAnchor),
            row.bottomAnchor.constraint(equalTo: valueLabel.bottomAnchor)
        ])

        return row
    }

    func listBlock(title: String, values: [String], monospaced: Bool = false) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        addFullWidth(label(title, font: .systemFont(ofSize: 12, weight: .medium), color: .tertiaryLabelColor), to: stack)

        let displayValues = values.isEmpty ? ["无"] : values
        for value in displayValues {
            addFullWidth(label(
                value,
                font: monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13),
                color: .labelColor
            ), to: stack)
        }

        return stack
    }

    func deviceValues(_ profile: IPAPreviewProvisioningProfile) -> [String] {
        if profile.provisionsAllDevices {
            return ["全部设备"]
        }
        return profile.provisionedDevices
    }

    func badge(_ text: String, tint: NSColor) -> NSView {
        let label = label(text.isEmpty ? "-" : text, font: .systemFont(ofSize: 12, weight: .semibold), color: tint)
        label.maximumNumberOfLines = 1

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        return container
    }

    func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let textField = NSTextField(labelWithString: text)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = font
        textField.textColor = color
        textField.alignment = .left
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 2
        textField.isSelectable = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    func certificateDescription(_ certificate: IPAPreviewCertificate) -> String {
        // 有效性状态前缀（最显眼）
        let status = certificate.validityStatus
        var statusText = "【\(status.label)】"
        if let days = certificate.daysUntilExpiry {
            if days > 0 {
                statusText += "(还剩 \(days) 天)"
            } else if days == 0 {
                statusText += "(今天到期)"
            } else {
                statusText += "(已过期 \(-days) 天)"
            }
        }

        var parts = [statusText, certificate.commonName]
        if !certificate.organization.isEmpty {
            parts.append(certificate.organization)
        }
        if !certificate.countryName.isEmpty {
            parts.append(certificate.countryName)
        }
        if !certificate.teamIdentifier.isEmpty {
            parts.append("Team ID: \(certificate.teamIdentifier)")
        }
        if let notBefore = certificate.notBefore {
            parts.append("生效: \(format(notBefore))")
        }
        if let notAfter = certificate.notAfter {
            parts.append("过期: \(format(notAfter))")
        }
        if !certificate.sha1Fingerprint.isEmpty {
            parts.append("SHA1: \(certificate.sha1Fingerprint)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
    }

    func validityText(for profile: IPAPreviewProvisioningProfile) -> String {
        let status = profile.validityStatus
        var text = status.label
        if let days = profile.daysUntilExpiry {
            if days > 0 {
                text += "（还剩 \(days) 天）"
            } else if days == 0 {
                text += "（今天到期）"
            } else {
                text += "（已过期 \(-days) 天）"
            }
        }
        return text
    }

    func validityColor(for status: ValidityStatus) -> NSColor {
        switch status {
        case .valid: return .systemGreen
        case .expiringSoon: return .systemOrange
        case .expired: return .systemRed
        case .notYetValid: return .systemYellow
        }
    }

    func highlightColor(for key: String, value: String) -> NSColor? {
        guard value != "-" else {
            return nil
        }
        switch key {
        case "有效性":
            if value.hasPrefix("已过期") { return .systemRed }
            if value.hasPrefix("即将过期") { return .systemOrange }
            if value.hasPrefix("未生效") { return .systemYellow }
            return .systemGreen
        case "类型":
            return .systemIndigo
        case "Team ID":
            return .systemGreen
        case "过期时间":
            return .systemOrange
        case "设备数":
            return .systemBlue
        case "证书数", "Entitlements":
            return .systemPurple
        case "APS", "调试权限":
            return .systemGreen
        default:
            return nil
        }
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
