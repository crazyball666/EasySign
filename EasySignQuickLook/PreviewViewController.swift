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
        contentStack.spacing = 12

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

            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
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
        iconView.layer?.cornerRadius = 15
        iconView.layer?.masksToBounds = true
        iconView.layer?.borderWidth = 1
        iconView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        iconView.image = info.iconData.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName)

        let titleStack = NSStackView()
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 5

        titleStack.addArrangedSubview(label(
            info.appName.isEmpty ? info.fileName : info.appName,
            font: .systemFont(ofSize: 21, weight: .bold),
            color: .labelColor
        ))
        titleStack.addArrangedSubview(label(
            info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier,
            font: .systemFont(ofSize: 12.5, weight: .regular),
            color: .secondaryLabelColor
        ))

        let badgeRow = NSStackView()
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY
        badgeRow.spacing = 6
        badgeRow.addArrangedSubview(badge(info.versionDescription, tint: .systemBlue))
        if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
            badgeRow.addArrangedSubview(badge("Team \(teamId)", tint: .systemGreen))
        }
        if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
            badgeRow.addArrangedSubview(badge(profileType, tint: .systemIndigo))
        }
        let badgeWrap = NSView()
        badgeWrap.translatesAutoresizingMaskIntoConstraints = false
        badgeWrap.addSubview(badgeRow)
        NSLayoutConstraint.activate([
            badgeRow.leadingAnchor.constraint(equalTo: badgeWrap.leadingAnchor),
            badgeRow.topAnchor.constraint(equalTo: badgeWrap.topAnchor),
            badgeRow.bottomAnchor.constraint(equalTo: badgeWrap.bottomAnchor),
            badgeRow.trailingAnchor.constraint(lessThanOrEqualTo: badgeWrap.trailingAnchor)
        ])
        titleStack.addArrangedSubview(badgeWrap)
        titleStack.setCustomSpacing(11, after: titleStack.arrangedSubviews[1])

        card.addSubview(iconView)
        card.addSubview(titleStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            titleStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            titleStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleStack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 16),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 20),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: titleStack.bottomAnchor, constant: 20)
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

        // 签名证书：逐张纵向彩色卡片（只用竖直流，避免横向固定尺寸约束冲突）
        addFullWidth(label("签名证书（\(profile.certificates.count)）",
                           font: .systemFont(ofSize: 12, weight: .medium),
                           color: .tertiaryLabelColor), to: stack)
        if profile.certificates.isEmpty {
            addFullWidth(label("无", font: .systemFont(ofSize: 13), color: .secondaryLabelColor), to: stack)
        } else {
            addFullWidth(certStatusBanner(profile.certificates), to: stack)
            for cert in profile.certificates {
                addFullWidth(certCardView(cert), to: stack)
            }
        }

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
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        return view
    }

    // 证书有效性配色
    func validityColor(_ status: ValidityStatus) -> NSColor {
        switch status {
        case .valid:        return .systemGreen
        case .expiringSoon: return .systemOrange
        case .expired:      return .systemRed
        case .notYetValid:  return .systemYellow
        }
    }

    func validityLabel(_ status: ValidityStatus, days: Int?) -> String {
        var text = status.label
        if let days {
            if days > 0 { text += " · 还剩 \(days) 天" }
            else if days == 0 { text += " · 今天到期" }
            else { text += " · 已过期 \(-days) 天" }
        }
        return text
    }

    // 单张证书：纯纵向卡片（只用 label/badge + addFullWidth，零固定尺寸横向约束）
    func certCardView(_ cert: IPAPreviewCertificate) -> NSView {
        let status = cert.validityStatus
        let tint = validityColor(status)

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        card.addSubview(stack)
        pin(stack, to: card, inset: 14)

        // 名称行
        var nameLine = cert.commonName.isEmpty ? "(无 CN)" : cert.commonName
        if !cert.organization.isEmpty { nameLine += "  ·  \(cert.organization)" }
        addFullWidth(label(nameLine, font: .systemFont(ofSize: 13.5, weight: .semibold), color: .labelColor), to: stack)

        // 状态胶囊（左对齐，不拉伸）
        addFullWidth(leftAligned(badge(validityLabel(status, days: cert.daysUntilExpiry), tint: tint)), to: stack)

        // 日期/团队行
        var meta: [String] = []
        if let nb = cert.notBefore { meta.append("生效 \(format(nb))") }
        if let na = cert.notAfter { meta.append("过期 \(format(na))") }
        if !cert.teamIdentifier.isEmpty { meta.append("Team \(cert.teamIdentifier)") }
        if !meta.isEmpty {
            addFullWidth(label(meta.joined(separator: "   "),
                              font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor), to: stack)
        }

        // SHA-1
        if !cert.sha1Fingerprint.isEmpty {
            addFullWidth(label("SHA-1  \(cert.sha1Fingerprint)",
                              font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
                              color: .tertiaryLabelColor), to: stack)
        }

        return card
    }

    // 证书总状态横幅
    func certStatusBanner(_ certs: [IPAPreviewCertificate]) -> NSView {
        let statuses = certs.map { $0.validityStatus }
        let allValid = !statuses.isEmpty && statuses.allSatisfy { $0 == .valid }
        let anyExpired = statuses.contains(.expired)
        let tint: NSColor = allValid ? .systemGreen : (anyExpired ? .systemRed : .systemOrange)
        let text = allValid ? "所有 \(certs.count) 张证书均在有效期内"
                            : (anyExpired ? "存在已过期的证书" : "部分证书即将过期")

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        card.addSubview(stack)
        pin(stack, to: card, inset: 10)
        addFullWidth(label(text, font: .systemFont(ofSize: 12.5, weight: .semibold), color: tint), to: stack)
        return card
    }

    func cardStack(title: String) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 9
        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        addFullWidth(titleLabel, to: stack)
        stack.setCustomSpacing(12, after: titleLabel)
        return stack
    }

    func keyValueRow(_ key: String, _ value: String, valueColor: NSColor? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = label(key, font: .systemFont(ofSize: 12.5, weight: .regular), color: .secondaryLabelColor)
        keyLabel.maximumNumberOfLines = 1
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.lineBreakMode = .byTruncatingTail

        let valueLabel = label(value, font: .systemFont(ofSize: 12.5, weight: valueColor == nil ? .regular : .semibold), color: valueColor ?? .labelColor)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(keyLabel)
        row.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: row.topAnchor),
            keyLabel.widthAnchor.constraint(equalToConstant: 92),

            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 16),
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
        let textLabel = label(text.isEmpty ? "-" : text, font: .systemFont(ofSize: 11.5, weight: .semibold), color: tint)
        textLabel.maximumNumberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
        container.addSubview(textLabel)
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            textLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        container.setContentHuggingPriority(.required, for: .horizontal)
        return container
    }

    /// 左对齐放一个不被拉伸的徽章（用横向 stack + 尾部弹性占位，安全无固定尺寸）
    func leftAligned(_ view: NSView) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.addArrangedSubview(view)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
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
