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
    let onDeviceSelected: () -> Void

    var body: some View {
        VStack(spacing: GlassMetric.spacingM) {
            HStack {
                GlassSectionTitle("设备", icon: "iphone.gen3")
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GlassIconButtonStyle())
            }
            .glassSurface(.inset, radius: GlassMetric.radiusMedium, padding: GlassMetric.spacingS)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: GlassMetric.spacingXS) {
                    ForEach(devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: selectedDevice?.id == device.id
                        ) {
                            selectedDevice = device
                            onDeviceSelected()
                        }
                    }
                }
            }
        }
        .glassSurface(.emphasized, radius: GlassMetric.radiusLarge, padding: GlassMetric.spacingM)
    }
}

struct DeviceRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let device: Device
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let palette = GlassPalette(colorScheme: colorScheme)
        Button(action: onTap) {
            HStack {
                Image(systemName: device.deviceClass == .iPhone ? "iphone" : "ipad")
                    .foregroundStyle(isSelected ? palette.onAccentText : palette.primaryStart)
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? palette.onAccentText : Color.primary)
                    Text(device.systemVersion)
                        .font(.caption)
                        .foregroundStyle(isSelected ? palette.onAccentText.opacity(0.82) : palette.mutedText)
                }
                Spacer()
                if device.interfaceType == .wireless {
                    Image(systemName: "wifi")
                        .font(.caption)
                        .foregroundStyle(isSelected ? palette.onAccentText : palette.primaryStart)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: GlassMetric.radiusSmall, style: .continuous)
                        .fill(palette.primaryGradient)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
