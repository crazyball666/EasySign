//
//  DeviceView.swift
//  EasySign
//
//  Created by crazyball on 2026/4/19.
//

import SwiftUI

struct SandboxBrowserView: View {
    let app: InstalledApp?
    let initialPath: String
    let onFileSelected: (FileNode) -> Void
    let onNavigateBack: () -> Void

    var body: some View {
        VStack {
            HStack {
                Button("Back to Apps") {
                    onNavigateBack()
                }
                Spacer()
            }
            .padding()

            if let app = app {
                Text("Sandbox: \(app.bundleID)")
                    .font(.headline)
                Text("SandboxBrowserView - Coming in Task 11")
                    .foregroundColor(.secondary)
            } else {
                Text("Select an app")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FilePreviewView: View {
    let app: InstalledApp?
    let path: String
    let onBack: () -> Void

    var body: some View {
        VStack {
            HStack {
                Button("Back") {
                    onBack()
                }
                Spacer()
            }
            .padding()

            if let app = app {
                Text("Preview: \(path)")
                    .font(.headline)
                Text("FilePreviewView - Coming in Task 12")
                    .foregroundColor(.secondary)
            } else {
                Text("Select a file to preview")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DeviceViewMode

enum DeviceViewMode {
    case appList
    case fileBrowser
    case filePreview
}

// MARK: - DeviceView

struct DeviceView: View {
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var selectedDevice: Device?
    @State private var selectedApp: InstalledApp?
    @State private var currentPath: String = ""
    @State private var viewMode: DeviceViewMode = .appList

    var body: some View {
        HStack(spacing: 0) {
            // 设备列表
            DeviceListPanel(
                devices: deviceManager.devices,
                selectedDevice: $selectedDevice,
                onRefresh: { deviceManager.refreshDevices() }
            )
            .frame(width: 150)

            Divider()

            // 主内容区
            Group {
                switch viewMode {
                case .appList:
                    AppListView(
                        device: selectedDevice,
                        onAppSelected: { app in
                            selectedApp = app
                            currentPath = "/"
                            viewMode = .fileBrowser
                        }
                    )
                case .fileBrowser:
                    SandboxBrowserView(
                        app: selectedApp,
                        initialPath: currentPath,
                        onFileSelected: { node in
                            if !node.isDirectory {
                                viewMode = .filePreview
                            }
                        },
                        onNavigateBack: {
                            viewMode = .appList
                        }
                    )
                case .filePreview:
                    FilePreviewView(
                        app: selectedApp,
                        path: currentPath,
                        onBack: {
                            viewMode = .fileBrowser
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            deviceManager.refreshDevices()
        }
    }
}
