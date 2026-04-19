//
//  DeviceView.swift
//  EasySign
//
//  Created by crazyball on 2026/4/19.
//

import SwiftUI

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
