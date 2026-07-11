//
//  IPAPreviewHTMLRenderer.swift
//  EasySign
//

import Foundation

enum IPAPreviewHTMLRenderer {
    static func html(for info: IPAPreviewInfo) -> String {
        let iconHTML: String
        if let iconData = info.iconData {
            iconHTML = #"<img class="icon" src="data:image/png;base64,\#(iconData.base64EncodedString())" />"#
        } else {
            iconHTML = #"<div class="icon placeholder">IPA</div>"#
        }

        var badges = #"<span class="badge badge-blue">\#(escape(info.versionDescription))</span>"#
        if let teamId = info.provisioningProfile?.teamIdentifier, !teamId.isEmpty {
            badges += #"<span class="badge badge-green">Team \#(escape(teamId))</span>"#
        }
        if let profileType = info.provisioningProfile?.profileType, !profileType.isEmpty {
            badges += #"<span class="badge badge-indigo">\#(escape(profileType))</span>"#
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(style)
        </style>
        </head>
        <body>
        <main>
            <header class="hero">
                \(iconHTML)
                <div class="hero-text">
                    <h1>\(escape(info.appName.isEmpty ? info.fileName : info.appName))</h1>
                    <p>\(escape(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier))</p>
                    <div class="badges">\(badges)</div>
                </div>
            </header>

            \(card("基础信息", "ℹ️", body: table(rows: [
                ("文件", info.fileName),
                ("App 目录", info.appDirectoryName),
                ("Bundle ID", info.bundleIdentifier),
                ("版本", info.versionDescription),
                ("最低系统", info.minimumOSVersion ?? "-"),
                ("可执行文件", info.executableName ?? "-")
            ])))

            \(card("签名信息", "🔏", body: table(rows: signingRows(for: info))))

            \(profileSection(info.provisioningProfile))

            \(certificatesSection(info.provisioningProfile))

            \(card("组件", "📦", body:
                listBlock("App Extension", values: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name) · \($0.bundleIdentifier)" }) +
                listBlock("Frameworks", values: info.frameworks) +
                listBlock("动态库", values: info.dynamicLibraries)
            ))
        </main>
        </body>
        </html>
        """
    }
}

private extension IPAPreviewHTMLRenderer {
    static var style: String {
        """
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif;
            background: Canvas;
            color: CanvasText;
            -webkit-font-smoothing: antialiased;
        }
        main { padding: 22px; max-width: 920px; margin: 0 auto; }

        /* Hero */
        .hero {
            display: flex;
            align-items: center;
            gap: 18px;
            padding: 20px;
            border-radius: 16px;
            margin-bottom: 18px;
            background: linear-gradient(135deg,
                color-mix(in srgb, AccentColor 12%, Canvas),
                Canvas);
            border: 1px solid color-mix(in srgb, CanvasText 8%, transparent);
        }
        .icon {
            width: 76px; height: 76px;
            border-radius: 17px;
            object-fit: cover;
            flex: 0 0 auto;
            box-shadow: 0 8px 22px rgba(0,0,0,.18);
        }
        .placeholder {
            display: grid; place-items: center;
            background: color-mix(in srgb, AccentColor 16%, Canvas);
            color: AccentColor; font-weight: 700; font-size: 20px;
        }
        .hero-text { min-width: 0; flex: 1; }
        h1 { font-size: 25px; line-height: 1.2; margin: 0 0 5px; }
        .hero-text p {
            margin: 0; color: GrayText; font-size: 13px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        .badges { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 6px; }
        .badge {
            font-size: 11px; font-weight: 600;
            padding: 3px 9px; border-radius: 7px; white-space: nowrap;
        }
        .badge-blue   { background: color-mix(in srgb, #0a84ff 16%, transparent); color: #0a84ff; }
        .badge-green  { background: color-mix(in srgb, #30d158 18%, transparent); color: #248a3d; }
        .badge-indigo { background: color-mix(in srgb, #5e5ce6 16%, transparent); color: #5e5ce6; }

        /* Cards */
        .card {
            background: color-mix(in srgb, CanvasText 3%, Canvas);
            border: 1px solid color-mix(in srgb, CanvasText 10%, transparent);
            border-radius: 14px;
            padding: 16px 18px;
            margin-bottom: 14px;
        }
        .card-title {
            display: flex; align-items: center; gap: 7px;
            font-size: 15px; font-weight: 600; margin: 0 0 12px;
        }
        .card-title .ico { font-size: 14px; }

        table { width: 100%; border-collapse: collapse; table-layout: fixed; }
        th, td {
            font-size: 13px; line-height: 1.5;
            padding: 6px 0; vertical-align: top; word-break: break-word;
            border-bottom: 1px solid color-mix(in srgb, CanvasText 6%, transparent);
        }
        tr:last-child th, tr:last-child td { border-bottom: none; }
        th {
            width: 96px; color: GrayText; text-align: left;
            padding-right: 14px; font-weight: 500;
        }
        td.tint-green  { color: #248a3d; font-weight: 600; }
        td.tint-orange { color: #c93400; font-weight: 600; }
        td.tint-red    { color: #d70015; font-weight: 600; }
        td.tint-yellow { color: #a16207; font-weight: 600; }
        td.tint-indigo { color: #5e5ce6; font-weight: 600; }
        td.tint-blue   { color: #0a84ff; font-weight: 600; }
        td.tint-purple { color: #8944ab; font-weight: 600; }

        .sub { font-size: 12px; font-weight: 600; color: GrayText; margin: 12px 0 5px; }
        ul { margin: 0; padding-left: 18px; }
        li { font-size: 12.5px; line-height: 1.55; margin: 2px 0; word-break: break-word; }
        .mono li, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; }
        .empty { color: GrayText; font-size: 13px; }

        /* Cert cards */
        .cert {
            display: flex; align-items: flex-start; gap: 12px;
            padding: 13px 14px; border-radius: 11px; margin-bottom: 10px;
            border: 1px solid;
        }
        .cert:last-child { margin-bottom: 0; }
        .cert-valid    { border-color: color-mix(in srgb, #30d158 45%, transparent); background: color-mix(in srgb, #30d158 7%, transparent); }
        .cert-soon     { border-color: color-mix(in srgb, #ff9f0a 50%, transparent); background: color-mix(in srgb, #ff9f0a 8%, transparent); }
        .cert-expired  { border-color: color-mix(in srgb, #ff453a 50%, transparent); background: color-mix(in srgb, #ff453a 8%, transparent); }
        .cert-notyet   { border-color: color-mix(in srgb, #ffd60a 55%, transparent); background: color-mix(in srgb, #ffd60a 10%, transparent); }
        .cert-dot { font-size: 22px; flex: 0 0 auto; line-height: 1.1; }
        .cert-body { min-width: 0; flex: 1; }
        .cert-name { font-size: 14px; font-weight: 600; margin: 0 0 3px; }
        .cert-org { font-size: 12px; color: GrayText; font-weight: 400; }
        .cert-meta { font-size: 12px; color: GrayText; margin-top: 4px; line-height: 1.5; }
        .cert-sha { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10.5px; color: GrayText; margin-top: 3px; word-break: break-all; }
        .cert-badge {
            flex: 0 0 auto; font-size: 12px; font-weight: 700;
            padding: 4px 10px; border-radius: 9px; text-align: center; white-space: nowrap;
        }
        .cert-badge small { display: block; font-size: 10px; font-weight: 500; opacity: .85; }
        .b-valid   { background: color-mix(in srgb, #30d158 20%, transparent); color: #248a3d; }
        .b-soon    { background: color-mix(in srgb, #ff9f0a 22%, transparent); color: #c93400; }
        .b-expired { background: color-mix(in srgb, #ff453a 20%, transparent); color: #d70015; }
        .b-notyet  { background: color-mix(in srgb, #ffd60a 28%, transparent); color: #a16207; }

        .banner {
            display: flex; align-items: center; gap: 9px;
            padding: 12px 14px; border-radius: 11px; margin-bottom: 12px;
            font-size: 13px; font-weight: 600; border: 1px solid;
        }
        .banner-ok   { background: color-mix(in srgb, #30d158 10%, transparent); border-color: color-mix(in srgb, #30d158 40%, transparent); color: #248a3d; }
        .banner-warn { background: color-mix(in srgb, #ff9f0a 10%, transparent); border-color: color-mix(in srgb, #ff9f0a 45%, transparent); color: #c93400; }
        .banner-bad  { background: color-mix(in srgb, #ff453a 10%, transparent); border-color: color-mix(in srgb, #ff453a 45%, transparent); color: #d70015; }
        """
    }

    // MARK: - Sections

    static func card(_ title: String, _ icon: String, body: String) -> String {
        """
        <section class="card">
            <div class="card-title"><span class="ico">\(icon)</span>\(escape(title))</div>
            \(body)
        </section>
        """
    }

    static func table(rows: [(String, String)], tints: [String: String] = [:]) -> String {
        let body = rows.map { key, value in
            let cls = tints[key].map { " class=\"tint-\($0)\"" } ?? ""
            return "<tr><th>\(escape(key))</th><td\(cls)>\(escape(value.isEmpty ? "-" : value))</td></tr>"
        }.joined(separator: "\n")
        return "<table>\(body)</table>"
    }

    static func listBlock(_ title: String, values: [String]) -> String {
        let content: String
        if values.isEmpty {
            content = #"<div class="empty">无</div>"#
        } else {
            content = #"<ul class="mono">\#(values.map { "<li>\(escape($0))</li>" }.joined())</ul>"#
        }
        return #"<div class="sub">\#(escape(title))（\#(values.count)）</div>\#(content)"#
    }

    static func signingRows(for info: IPAPreviewInfo) -> [(String, String)] {
        [
            ("签名状态", info.signingDescription),
            ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
        ]
    }

    static func profileSection(_ profile: IPAPreviewProvisioningProfile?) -> String {
        guard let profile else {
            return card("描述文件", "📄", body: table(rows: [("状态", "未内嵌描述文件")]))
        }

        let validity = validityText(profile)
        let rows: [(String, String)] = [
            ("有效性", validity),
            ("名称", profile.name),
            ("类型", profile.profileType),
            ("Team Name", profile.teamName),
            ("Team ID", profile.teamIdentifier),
            ("App ID", profile.applicationIdentifier),
            ("UUID", profile.uuid),
            ("创建时间", format(profile.creationDate)),
            ("过期时间", format(profile.expirationDate)),
            ("设备数", profile.provisionsAllDevices ? "全部设备" : "\(profile.provisionedDeviceCount)"),
            ("Entitlements", "\(profile.entitlementKeys.count)"),
            ("APS", profile.apsEnvironment ?? "-"),
            ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
        ]
        let tints: [String: String] = [
            "有效性": validityTint(profile.validityStatus),
            "类型": "indigo",
            "Team ID": "green",
            "过期时间": validityTint(profile.validityStatus)
        ]

        let detail = card("描述文件", "📄", body:
            table(rows: rows, tints: tints) +
            listBlock("已注册设备", values: deviceValues(profile)) +
            listBlock("Entitlements", values: profile.entitlementKeys)
        )
        return detail
    }

    static func certificatesSection(_ profile: IPAPreviewProvisioningProfile?) -> String {
        guard let certs = profile?.certificates, !certs.isEmpty else { return "" }

        let statuses = certs.map { $0.validityStatus }
        let allValid = statuses.allSatisfy { $0 == .valid }
        let anyExpired = statuses.contains(.expired)
        let bannerCls = allValid ? "banner-ok" : (anyExpired ? "banner-bad" : "banner-warn")
        let bannerIcon = allValid ? "✅" : (anyExpired ? "⛔️" : "⚠️")
        let bannerText = allValid
            ? "所有 \(certs.count) 张证书均在有效期内"
            : (anyExpired ? "存在已过期的证书" : "部分证书即将过期")

        let banner = #"<div class="banner \#(bannerCls)"><span>\#(bannerIcon)</span><span>\#(escape(bannerText))</span></div>"#

        let cards = certs.map { certCard($0) }.joined()
        return card("签名证书（\(certs.count)）", "🔑", body: banner + cards)
    }

    static func certCard(_ cert: IPAPreviewCertificate) -> String {
        let status = cert.validityStatus
        let (cardCls, badgeCls, dot): (String, String, String)
        switch status {
        case .valid:        (cardCls, badgeCls, dot) = ("cert-valid", "b-valid", "🟢")
        case .expiringSoon: (cardCls, badgeCls, dot) = ("cert-soon", "b-soon", "🟠")
        case .expired:      (cardCls, badgeCls, dot) = ("cert-expired", "b-expired", "🔴")
        case .notYetValid:  (cardCls, badgeCls, dot) = ("cert-notyet", "b-notyet", "🟡")
        }

        var daysText = ""
        if let days = cert.daysUntilExpiry {
            if days > 0 { daysText = "还剩 \(days) 天" }
            else if days == 0 { daysText = "今天到期" }
            else { daysText = "已过期 \(-days) 天" }
        }

        var meta: [String] = []
        if let nb = cert.notBefore { meta.append("生效 \(format(nb))") }
        if let na = cert.notAfter { meta.append("过期 \(format(na))") }
        if !cert.teamIdentifier.isEmpty { meta.append("Team \(cert.teamIdentifier)") }
        let metaLine = meta.joined(separator: " · ")

        let orgHTML = cert.organization.isEmpty ? "" : #" <span class="cert-org">\#(escape(cert.organization))</span>"#
        let shaHTML = cert.sha1Fingerprint.isEmpty ? "" : #"<div class="cert-sha">SHA-1 \#(escape(cert.sha1Fingerprint))</div>"#

        return """
        <div class="cert \(cardCls)">
            <div class="cert-dot">\(dot)</div>
            <div class="cert-body">
                <div class="cert-name">\(escape(cert.commonName.isEmpty ? "(无 CN)" : cert.commonName))\(orgHTML)</div>
                <div class="cert-meta">\(escape(metaLine))</div>
                \(shaHTML)
            </div>
            <div class="cert-badge \(badgeCls)">\(escape(status.label))<small>\(escape(daysText))</small></div>
        </div>
        """
    }

    // MARK: - Helpers

    static func validityText(_ profile: IPAPreviewProvisioningProfile) -> String {
        var text = profile.validityStatus.label
        if let days = profile.daysUntilExpiry {
            if days > 0 { text += "（还剩 \(days) 天）" }
            else if days == 0 { text += "（今天到期）" }
            else { text += "（已过期 \(-days) 天）" }
        }
        return text
    }

    static func validityTint(_ status: ValidityStatus) -> String {
        switch status {
        case .valid: return "green"
        case .expiringSoon: return "orange"
        case .expired: return "red"
        case .notYetValid: return "yellow"
        }
    }

    static func deviceValues(_ profile: IPAPreviewProvisioningProfile) -> [String] {
        if profile.provisionsAllDevices { return ["全部设备"] }
        return profile.provisionedDevices
    }

    static func format(_ date: Date?) -> String {
        guard let date else { return "-" }
        return format(date)
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
