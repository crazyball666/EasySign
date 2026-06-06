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

        addCard(headerCard(info: info))
        addCard(summaryGrid(info: info))
        addCard(signingCard(info: info))
        if let profile = info.provisioningProfile {
            addCard(profileHeroCard(profile))
            addCard(profileDetailCard(profile))
            if !profile.certificates.isEmpty {
                addCard(overallCertStatusCard(profile.certificates))
                for (i, cert) in profile.certificates.enumerated() {
                    addCard(certificateCard(cert, index: i))
                }
            }
        }
        addCard(contentsCard(info: info))
    }

    func addCard(_ card: NSView) {
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    // MARK: - Hero header

    func headerCard(info: IPAPreviewInfo) -> NSView {
        let card = cardContainer(tint: NSColor.controlAccentColor.withAlphaComponent(0.05),
                                  borderTint: NSColor.controlAccentColor.withAlphaComponent(0.30))

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 16
        iconView.layer?.masksToBounds = true
        iconView.image = info.iconData.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName)

        let titleStack = NSStackView()
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 6

        titleStack.addArrangedSubview(textLabel(
            info.appName.isEmpty ? info.fileName : info.appName,
            font: .systemFont(ofSize: 26, weight: .semibold),
            color: .labelColor, lineLimit: 1
        ))
        titleStack.addArrangedSubview(textLabel(
            info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier,
            font: .systemFont(ofSize: 13, weight: .medium),
            color: .secondaryLabelColor, lineLimit: 1
        ))

        let badgeRow = NSStackView()
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY
        badgeRow.spacing = 6
        badgeRow.addArrangedSubview(iconBadge(info.versionDescription, icon: "tag", tint: .systemBlue))
        if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
            badgeRow.addArrangedSubview(iconBadge("Team \(teamId)", icon: "person.3", tint: .systemGreen))
        }
        if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
            badgeRow.addArrangedSubview(iconBadge(profileType, icon: "doc.badge.gearshape", tint: .systemIndigo))
        }
        titleStack.addArrangedSubview(badgeRow)

        let meta = NSStackView()
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.orientation = .vertical
        meta.alignment = .trailing
        meta.spacing = 3
        meta.addArrangedSubview(textLabel(info.fileName, font: .systemFont(ofSize: 11, weight: .regular),
                                          color: .secondaryLabelColor, lineLimit: 1))
        meta.addArrangedSubview(textLabel(formatFileSize(info.fileSize), font: .systemFont(ofSize: 10),
                                          color: .tertiaryLabelColor, lineLimit: 1))

        card.addSubview(iconView)
        card.addSubview(titleStack)
        card.addSubview(meta)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            titleStack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 18),
            titleStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            meta.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            meta.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: meta.leadingAnchor, constant: -12),

            card.bottomAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 22),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: titleStack.bottomAnchor, constant: 22)
        ])

        return card
    }

    // MARK: - Summary

    func summaryGrid(info: IPAPreviewInfo) -> NSView {
        return sectionCard(title: "基础信息", icon: "info.circle", rows: [
            ("文件", info.fileName),
            ("App 目录", info.appDirectoryName),
            ("Bundle ID", info.bundleIdentifier),
            ("版本", info.versionDescription),
            ("最低系统", info.minimumOSVersion ?? "-"),
            ("可执行文件", info.executableName ?? "-")
        ])
    }

    func signingCard(info: IPAPreviewInfo) -> NSView {
        return sectionCard(title: "签名信息", icon: "signature", rows: [
            ("状态", info.signingDescription),
            ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
        ])
    }

    // MARK: - Profile

    func profileHeroCard(_ profile: IPAPreviewProvisioningProfile) -> NSView {
        let status = profile.validityStatus
        let tint = colorForValidity(status)

        let card = cardContainer(tint: tint.withAlphaComponent(0.06),
                                  borderTint: tint.withAlphaComponent(0.4))

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "doc.badge.gearshape.fill",
                              accessibilityDescription: nil)
        icon.contentTintColor = .systemIndigo
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(textLabel(profile.name,
            font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor, lineLimit: 1))
        titleStack.addArrangedSubview(textLabel(profile.profileType,
            font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lineLimit: 1))

        let badge = validityBadge(status: status, daysLeft: profile.daysUntilExpiry)

        header.addArrangedSubview(icon)
        header.addArrangedSubview(titleStack)
        let spacer = NSView()
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(badge)

        let dates = NSStackView()
        dates.translatesAutoresizingMaskIntoConstraints = false
        dates.orientation = .horizontal
        dates.distribution = .fillEqually
        dates.spacing = 24

        dates.addArrangedSubview(dateBlock(
            label: "生效",
            date: profile.creationDate,
            color: .secondaryLabelColor
        ))
        dates.addArrangedSubview(dateBlock(
            label: "过期",
            date: profile.expirationDate,
            color: tint
        ))

        card.addSubview(header)
        card.addSubview(dates)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            dates.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            dates.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            dates.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            dates.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return card
    }

    func profileDetailCard(_ profile: IPAPreviewProvisioningProfile) -> NSView {
        return sectionCard(title: "描述文件详情", icon: "doc.text", rows: [
            ("UUID", profile.uuid),
            ("Team Name", profile.teamName),
            ("Team ID", profile.teamIdentifier),
            ("App ID", profile.applicationIdentifier),
            ("创建时间", format(profile.creationDate)),
            ("过期时间", format(profile.expirationDate)),
            ("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)"),
            ("Entitlements", "\(profile.entitlementKeys.count)"),
            ("APS", profile.apsEnvironment ?? "-"),
            ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
        ])
    }

    // MARK: - Certificates

    func overallCertStatusCard(_ certs: [IPAPreviewCertificate]) -> NSView {
        let statuses = certs.map { $0.validityStatus }
        let allValid = !statuses.isEmpty && statuses.allSatisfy { $0 == .valid }
        let anyExpired = statuses.contains(.expired)
        let tint: NSColor = allValid ? .systemGreen : (anyExpired ? .systemRed : .systemOrange)
        let iconName = allValid ? "checkmark.seal.fill" : (anyExpired ? "xmark.seal.fill" : "exclamationmark.triangle.fill")
        let text = allValid
            ? "所有 \(certs.count) 张证书均在有效期内"
            : (anyExpired ? "存在已过期的证书" : "部分证书即将过期")

        let card = cardContainer(tint: tint.withAlphaComponent(0.10),
                                  borderTint: tint.withAlphaComponent(0.4))

        let h = NSStackView()
        h.translatesAutoresizingMaskIntoConstraints = false
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 10

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        h.addArrangedSubview(icon)
        h.addArrangedSubview(textLabel(text, font: .systemFont(ofSize: 13, weight: .semibold), color: tint, lineLimit: 1))

        card.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            h.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            h.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        return card
    }

    func certificateCard(_ cert: IPAPreviewCertificate, index: Int) -> NSView {
        let status = cert.validityStatus
        let tint = colorForValidity(status)
        let card = cardContainer(tint: NSColor.clear, borderTint: tint.withAlphaComponent(0.4))

        let iconCircle = NSView()
        iconCircle.translatesAutoresizingMaskIntoConstraints = false
        iconCircle.wantsLayer = true
        iconCircle.layer?.cornerRadius = 24
        iconCircle.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: validityIconName(status), accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown
        iconCircle.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])

        let info = NSStackView()
        info.translatesAutoresizingMaskIntoConstraints = false
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 4

        // 标题行：CN + 验证状态
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.addArrangedSubview(textLabel(
            cert.commonName.isEmpty ? "(无 CN)" : cert.commonName,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor, lineLimit: 1
        ))
        if !cert.organization.isEmpty {
            titleRow.addArrangedSubview(textLabel(cert.organization,
                font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lineLimit: 1))
        }
        info.addArrangedSubview(titleRow)

        // 日期行
        let dateRow = NSStackView()
        dateRow.orientation = .horizontal
        dateRow.spacing = 14
        if let notBefore = cert.notBefore {
            dateRow.addArrangedSubview(dateChip(icon: "play.circle", label: "生效",
                value: notBefore, color: .secondaryLabelColor))
        }
        if let notAfter = cert.notAfter {
            dateRow.addArrangedSubview(dateChip(icon: "stop.circle", label: "过期",
                value: notAfter, color: tint))
        }
        info.addArrangedSubview(dateRow)

        // SHA-1
        if !cert.sha1Fingerprint.isEmpty {
            let shaRow = NSStackView()
            shaRow.orientation = .horizontal
            shaRow.spacing = 4
            shaRow.addArrangedSubview(textLabel("SHA-1:",
                font: .systemFont(ofSize: 10), color: .secondaryLabelColor))
            shaRow.addArrangedSubview(textLabel(cert.sha1Fingerprint,
                font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                color: .secondaryLabelColor, lineLimit: 1, isSelectable: true))
            info.addArrangedSubview(shaRow)
        }

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 3
        right.addArrangedSubview(validityBadge(status: status, daysLeft: cert.daysUntilExpiry))
        if !cert.teamIdentifier.isEmpty {
            right.addArrangedSubview(textLabel("Team \(cert.teamIdentifier)",
                font: .systemFont(ofSize: 10), color: .secondaryLabelColor))
        }

        card.addSubview(iconCircle)
        card.addSubview(info)
        card.addSubview(right)

        NSLayoutConstraint.activate([
            iconCircle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            iconCircle.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            iconCircle.widthAnchor.constraint(equalToConstant: 48),
            iconCircle.heightAnchor.constraint(equalToConstant: 48),

            info.leadingAnchor.constraint(equalTo: iconCircle.trailingAnchor, constant: 14),
            info.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            info.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            info.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            right.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }

    // MARK: - Contents

    func contentsCard(info: IPAPreviewInfo) -> NSView {
        let card = cardContainer()
        let stack = cardStack(title: "App Extension · Frameworks · 动态库", icon: "shippingbox")
        card.addSubview(stack)
        pin(stack, to: card, inset: 18)

        addFullWidth(listBlock(title: "App Extension",
                                values: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name) · \($0.bundleIdentifier)" },
                                monospaced: false), to: stack)
        addFullWidth(separator(), to: stack)
        addFullWidth(listBlock(title: "Frameworks", values: info.frameworks, monospaced: true), to: stack)
        addFullWidth(separator(), to: stack)
        addFullWidth(listBlock(title: "动态库", values: info.dynamicLibraries, monospaced: true), to: stack)
        return card
    }

    // MARK: - Card primitives

    func sectionCard(title: String, icon: String, rows: [(String, String)]) -> NSView {
        let card = cardContainer()
        let stack = cardStack(title: title, icon: icon)
        card.addSubview(stack)
        pin(stack, to: card, inset: 18)

        for (i, row) in rows.enumerated() {
            addFullWidth(keyValueRow(row.0, row.1.isEmpty ? "-" : row.1), to: stack)
            if i < rows.count - 1 {
                addFullWidth(separator(), to: stack)
            }
        }
        return card
    }

    func cardContainer(tint: NSColor = .clear, borderTint: NSColor = .clear) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        if borderTint != .clear {
            view.layer?.borderWidth = 1
            view.layer?.borderColor = borderTint.cgColor
        } else {
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        }
        if tint != .clear {
            // tint 在 view 上方叠一个半透明色块
            let tintLayer = CALayer()
            tintLayer.backgroundColor = tint.cgColor
            tintLayer.cornerRadius = 14
            view.layer?.addSublayer(tintLayer)
            // 同步 tint layer 尺寸
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                tintLayer.frame = view.bounds
            }
        }
        return view
    }

    func cardStack(title: String, icon: String? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        if let icon {
            let headerRow = NSStackView()
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 6
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
            headerRow.addArrangedSubview(iconView)
            headerRow.addArrangedSubview(textLabel(title,
                font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor, lineLimit: 1))
            stack.addArrangedSubview(headerRow)
        } else {
            stack.addArrangedSubview(textLabel(title,
                font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor, lineLimit: 1))
        }
        return stack
    }

    func keyValueRow(_ key: String, _ value: String, valueColor: NSColor? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = textLabel(key,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .tertiaryLabelColor, lineLimit: 1)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = textLabel(value,
            font: .systemFont(ofSize: 12, weight: valueColor == nil ? .regular : .medium),
            color: valueColor ?? .labelColor, lineLimit: 2, isSelectable: true)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(keyLabel)
        row.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            keyLabel.widthAnchor.constraint(equalToConstant: 96),

            valueLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: row.topAnchor),
            valueLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -1)
        ])
        return row
    }

    func listBlock(title: String, values: [String], monospaced: Bool = false) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        addFullWidth(textLabel(title,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .tertiaryLabelColor, lineLimit: 1), to: stack)

        let displayValues = values.isEmpty ? ["无"] : values
        for value in displayValues {
            addFullWidth(textLabel(value,
                font: monospaced
                    ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                    : .systemFont(ofSize: 13),
                color: .labelColor, lineLimit: 1, isSelectable: true), to: stack)
        }
        return stack
    }

    func iconBadge(_ text: String, icon: String, tint: NSColor) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor

        let h = NSStackView()
        h.translatesAutoresizingMaskIntoConstraints = false
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 4
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = tint
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 10).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 10).isActive = true
        h.addArrangedSubview(iconView)
        h.addArrangedSubview(textLabel(text.isEmpty ? "-" : text,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: tint, lineLimit: 1))
        container.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            h.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            h.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            h.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        return container
    }

    func validityBadge(status: ValidityStatus, daysLeft: Int?) -> NSView {
        let tint = colorForValidity(status)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = tint.withAlphaComponent(0.5).cgColor

        let v = NSStackView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 1

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 4
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: validityIconName(status), accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        topRow.addArrangedSubview(icon)
        topRow.addArrangedSubview(textLabel(status.label,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: tint, lineLimit: 1))
        v.addArrangedSubview(topRow)

        if let days = daysLeft {
            v.addArrangedSubview(textLabel(daysText(days),
                font: .systemFont(ofSize: 10),
                color: tint, lineLimit: 1))
        }

        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    func dateBlock(label: String, date: Date?, color: NSColor) -> NSView {
        let v = NSStackView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        v.addArrangedSubview(textLabel(label,
            font: .systemFont(ofSize: 10), color: .secondaryLabelColor, lineLimit: 1))
        if let date {
            v.addArrangedSubview(textLabel(format(date),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: color, lineLimit: 1))
        } else {
            v.addArrangedSubview(textLabel("-",
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: .secondaryLabelColor, lineLimit: 1))
        }
        return v
    }

    func dateChip(icon: String, label: String, value: Date, color: NSColor) -> NSView {
        let h = NSStackView()
        h.translatesAutoresizingMaskIntoConstraints = false
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 3
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = color
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 11).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 11).isActive = true
        h.addArrangedSubview(iconView)
        h.addArrangedSubview(textLabel("\(label) \(format(value))",
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: color, lineLimit: 1))
        return h
    }

    // MARK: - Helpers

    func colorForValidity(_ status: ValidityStatus) -> NSColor {
        switch status {
        case .valid: return .systemGreen
        case .expiringSoon: return .systemOrange
        case .expired: return .systemRed
        case .notYetValid: return .systemYellow
        }
    }

    func validityIconName(_ status: ValidityStatus) -> String {
        switch status {
        case .valid: return "checkmark.seal.fill"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "xmark.seal.fill"
        case .notYetValid: return "hourglass"
        }
    }

    func daysText(_ days: Int) -> String {
        if days > 0 { return "还剩 \(days) 天" }
        if days == 0 { return "今天到期" }
        return "已过期 \(-days) 天"
    }

    func textLabel(_ text: String, font: NSFont, color: NSColor, lineLimit: Int = 0, isSelectable: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = font
        field.textColor = color
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        if lineLimit > 0 {
            field.maximumNumberOfLines = lineLimit
        }
        field.isSelectable = isSelectable
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
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

    func format(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    func formatFileSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
