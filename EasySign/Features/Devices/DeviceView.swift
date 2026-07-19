//
//  DeviceView.swift
//  EasySign
//
//  Created by crazyball on 2026/4/19.
//

import SwiftUI

// MARK: - BrowseMode

enum BrowseMode: String, CaseIterable, Hashable {
    case apps = "Apps"
    case media = "Media"
}

// MARK: - DeviceView

struct DeviceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var selectedDevice: Device?
    @State private var mode: BrowseMode = .apps
    @State private var selectedApp: InstalledApp?      // non-nil → showing app's sandbox
    @State private var previewFile: FileNode?          // non-nil → showing file preview
    @State private var appListRefreshTrigger: Int = 0

    private var palette: GlassPalette { GlassPalette(colorScheme: colorScheme) }

    var body: some View {
        GlassCanvas {
            GeometryReader { proxy in
                let usesInspector = GlassLayout.contextPresentation(for: proxy.size.width) == .inspector
                VStack(alignment: .leading, spacing: GlassMetric.spacingL) {
                    WorkspaceHeader(icon: "iphone", title: "设备工作台", subtitle: "浏览 iOS 应用沙盒与媒体文件", status: selectedDevice == nil ? .idle : .success, statusTitle: selectedDevice == nil ? "等待设备" : "设备已连接") {
                        HStack(spacing: GlassMetric.spacingM) {
                            if selectedDevice != nil { modeSegment }
                            if usesInspector {
                                GlassInspectorButton(title: "设备信息") { DeviceConnectionRail(device: selectedDevice, mode: mode).padding(GlassMetric.spacingS) }
                            }
                        }
                    }
                    HStack(spacing: GlassMetric.spacingL) {
                        DeviceListPanel(devices: deviceManager.devices, selectedDevice: $selectedDevice, onRefresh: { deviceManager.refreshDevices() }, onDeviceSelected: resetSelection)
                            .frame(width: 150)
                        mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !usesInspector { DeviceConnectionRail(device: selectedDevice, mode: mode).frame(width: 270) }
                    }
                }
                .glassWorkspacePadding()
            }
        }
        .onAppear {
            deviceManager.startObserving()
            deviceManager.refreshDevices()
        }
        .onDisappear {
            deviceManager.stopObserving()
        }
    }

    private func resetSelection() {
        selectedApp = nil
        previewFile = nil
        appListRefreshTrigger += 1
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if selectedDevice == nil {
            placeholder("从左侧选择一台设备")
        } else {
            bodyForMode
        }
    }

    // Lives in the workspace header's trailing slot: a dedicated segment row above
    // the browser would cost ~60pt of the app list's visible area for one control.
    private var modeSegment: some View {
        Picker("", selection: $mode) {
            ForEach(BrowseMode.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 168)
        .onChange(of: mode) { _, _ in
            // Switching mode collapses any deeper navigation in the previous mode.
            selectedApp = nil
            previewFile = nil
        }
    }

    // Preview is layered ON TOP of the browser instead of replacing it, so the
    // browser's @State (currentPath, pathHistory) survives the round-trip. Without
    // this, backing out of a file preview would always land at the root.
    @ViewBuilder
    private var bodyForMode: some View {
        ZStack {
            modeBrowser

            if let file = previewFile, let source = currentSource {
                FilePreviewView(
                    source: source,
                    path: file.path,
                    onBack: { previewFile = nil }
                )
                .background(palette.canvas)
            }
        }
    }

    @ViewBuilder
    private var modeBrowser: some View {
        switch mode {
        case .apps:
            if let app = selectedApp {
                SandboxBrowserView(
                    source: .appSandbox(app),
                    onFileSelected: { node in previewFile = node },
                    onNavigateBack: { selectedApp = nil }
                )
            } else if let device = selectedDevice {
                AppListView(
                    device: device,
                    onAppSelected: { app in selectedApp = app }
                )
                .id(appListRefreshTrigger)
            }
        case .media:
            if let device = selectedDevice {
                SandboxBrowserView(
                    source: .media(device),
                    onFileSelected: { node in previewFile = node },
                    onNavigateBack: {}    // disabled at media root
                )
            }
        }
    }

    private var currentSource: SandboxBrowserView.Source? {
        switch mode {
        case .apps:
            return selectedApp.map { .appSandbox($0) }
        case .media:
            return selectedDevice.map { .media($0) }
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        VStack(spacing: GlassMetric.spacingM) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.mutedText)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(.inset, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingXL)
    }
}
