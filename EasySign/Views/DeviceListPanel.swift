//
//  DeviceListPanel.swift
//  EasySign
//
//  Created by crazyball on 2026/4/19.
//

import SwiftUI

struct DeviceListPanel: View {
    let devices: [Device]
    @Binding var selectedDevice: Device?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: selectedDevice?.id == device.id
                        ) {
                            selectedDevice = device
                        }
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.05))
    }
}

struct DeviceRow: View {
    let device: Device
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: device.deviceClass == .iPhone ? "iphone" : "ipad")
                    .foregroundColor(.primary)
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(device.systemVersion)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
