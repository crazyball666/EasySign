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

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(style)
        </style>
        </head>
        <body>
        <main>
            <header>
                \(iconHTML)
                <div>
                    <h1>\(escape(info.appName.isEmpty ? info.fileName : info.appName))</h1>
                    <p>\(escape(info.bundleIdentifier.isEmpty ? "未读取到 Bundle ID" : info.bundleIdentifier))</p>
                </div>
            </header>
            \(section("基础信息", rows: [
                ("文件", info.fileName),
                ("App 目录", info.appDirectoryName),
                ("Bundle ID", info.bundleIdentifier),
                ("版本", info.versionDescription),
                ("最低系统", info.minimumOSVersion ?? "-"),
                ("可执行文件", info.executableName ?? "-")
            ]))
            \(section("签名信息", rows: signingRows(for: info)))
            \(profileSection(info.provisioningProfile))
            \(listSection("App Extension", values: info.appexes.map { "\($0.name.isEmpty ? $0.bundleIdentifier : $0.name)  \($0.bundleIdentifier)" }))
            \(listSection("Frameworks", values: info.frameworks))
            \(listSection("动态库", values: info.dynamicLibraries))
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
        body {
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif;
            background: Canvas;
            color: CanvasText;
        }
        main {
            box-sizing: border-box;
            width: 100%;
            min-height: 100vh;
            padding: 26px;
        }
        header {
            display: flex;
            align-items: center;
            gap: 16px;
            margin-bottom: 22px;
        }
        .icon {
            width: 72px;
            height: 72px;
            border-radius: 16px;
            object-fit: cover;
            flex: 0 0 auto;
            box-shadow: 0 10px 24px rgba(0,0,0,.16);
        }
        .placeholder {
            display: grid;
            place-items: center;
            background: color-mix(in srgb, AccentColor 14%, Canvas);
            color: AccentColor;
            font-weight: 700;
        }
        h1 {
            font-size: 24px;
            line-height: 1.2;
            margin: 0 0 6px;
        }
        p {
            margin: 0;
            color: GrayText;
            font-size: 13px;
        }
        section {
            border-top: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
            padding-top: 14px;
            margin-top: 18px;
        }
        h2 {
            font-size: 15px;
            margin: 0 0 10px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            table-layout: fixed;
        }
        th, td {
            font-size: 13px;
            line-height: 1.45;
            padding: 5px 0;
            vertical-align: top;
            word-break: break-word;
        }
        th {
            width: 118px;
            color: GrayText;
            text-align: right;
            padding-right: 14px;
            font-weight: 600;
        }
        ul {
            margin: 0;
            padding-left: 18px;
        }
        li {
            font-size: 13px;
            line-height: 1.55;
            margin: 2px 0;
            word-break: break-word;
        }
        .empty {
            color: GrayText;
            font-size: 13px;
        }
        """
    }

    static func signingRows(for info: IPAPreviewInfo) -> [(String, String)] {
        [
            ("签名状态", info.signingDescription),
            ("CodeResources", info.codeSignature.codeResourcesPath ?? "未发现")
        ]
    }

    static func profileSection(_ profile: IPAPreviewProvisioningProfile?) -> String {
        guard let profile else {
            return section("描述文件", rows: [("状态", "未内嵌描述文件")])
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
            ("证书数", "\(profile.certificates.count)"),
            ("Entitlements", "\(profile.entitlementKeys.count)"),
            ("APS", profile.apsEnvironment ?? "-"),
            ("调试权限", profile.getTaskAllow.map { $0 ? "YES" : "NO" } ?? "-")
        ]

        return section("描述文件", rows: rows) +
            listSection("设备列表", values: deviceValues(profile)) +
            listSection("签名证书", values: profile.certificates.map(certificateDescription)) +
            listSection("Entitlements", values: profile.entitlementKeys)
    }

    static func section(_ title: String, rows: [(String, String)]) -> String {
        let body = rows.map { key, value in
            "<tr><th>\(escape(key))</th><td>\(escape(value.isEmpty ? "-" : value))</td></tr>"
        }.joined(separator: "\n")
        return """
        <section>
            <h2>\(escape(title))</h2>
            <table>
                \(body)
            </table>
        </section>
        """
    }

    static func listSection(_ title: String, values: [String]) -> String {
        let content: String
        if values.isEmpty {
            content = #"<div class="empty">无</div>"#
        } else {
            content = "<ul>\(values.map { "<li>\(escape($0))</li>" }.joined())</ul>"
        }
        return """
        <section>
            <h2>\(escape(title))</h2>
            \(content)
        </section>
        """
    }

    static func certificateDescription(_ certificate: IPAPreviewCertificate) -> String {
        var parts = [certificate.commonName]
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

    static func deviceValues(_ profile: IPAPreviewProvisioningProfile) -> [String] {
        if profile.provisionsAllDevices {
            return ["全部设备"]
        }
        return profile.provisionedDevices
    }

    static func format(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
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
