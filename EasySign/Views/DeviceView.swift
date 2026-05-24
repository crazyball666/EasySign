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
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var selectedDevice: Device?
    @State private var mode: BrowseMode = .apps
    @State private var selectedApp: InstalledApp?      // non-nil → showing app's sandbox
    @State private var previewFile: FileNode?          // non-nil → showing file preview
    @State private var appListRefreshTrigger: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            DeviceListPanel(
                devices: deviceManager.devices,
                selectedDevice: $selectedDevice,
                onRefresh: { deviceManager.refreshDevices() },
                onDeviceSelected: {
                    // Reset deeper state when device changes.
                    selectedApp = nil
                    previewFile = nil
                    appListRefreshTrigger += 1
                }
            )
            .frame(width: 150)

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            deviceManager.startObserving()
            deviceManager.refreshDevices()
        }
        .onDisappear {
            deviceManager.stopObserving()
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if selectedDevice == nil {
            placeholder("从左侧选择一台设备")
        } else {
            VStack(spacing: 0) {
                modeSegment
                Divider()
                bodyForMode
            }
        }
    }

    private var modeSegment: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(BrowseMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.06))
        .onChange(of: mode) { _ in
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
                .background(Color(NSColor.windowBackgroundColor))
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
        VStack {
            Spacer()
            Text(text)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
