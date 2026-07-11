//
//  IPAContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/11/30.
//

import Foundation
import SwiftUI

struct ResignSetting {
    var bundleId: String
    var displayName: String
    var version: String
    var buildVersion: String
    var entitlements: String
    
    init(bundleId: String = "", displayName: String = "", version: String = "", buildVersion: String = "", entitlements: String = "") {
        self.bundleId = bundleId
        self.displayName = displayName
        self.version = version
        self.buildVersion = buildVersion
        self.entitlements = entitlements
    }
}


struct IPAContentView: View {
    @Binding var resignSetting: ResignSetting
    
    var body: some View {
        GlassCanvas {
            VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                WorkspaceHeader(icon: "slider.horizontal.3", title: "应用信息", subtitle: "修改会应用到本次重签任务")

                VStack(alignment: .leading, spacing: GlassMetric.spacingM) {
                    editorRow("应用名称", text: $resignSetting.displayName)
                    editorRow("应用包名", text: $resignSetting.bundleId)
                    editorRow("应用版本", text: $resignSetting.version)
                    editorRow("构建版本", text: $resignSetting.buildVersion)

                    VStack(alignment: .leading, spacing: GlassMetric.spacingS) {
                        GlassSectionTitle("权限信息", icon: "checkmark.shield")
                        TextEditor(text: $resignSetting.entitlements)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(GlassMetric.spacingS)
                            .frame(height: 200)
                            .glassSurface(.inset, radius: GlassMetric.radiusSmall, padding: 0)
                    }
                }
                .glassSurface(.standard, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingL)
            }
            .padding(GlassMetric.spacingL)
        }
        .frame(width: 600)
    }

    private func editorRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: GlassMetric.spacingM) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
