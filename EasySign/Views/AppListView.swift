import SwiftUI

struct AppListView: View {
    let device: Device?
    let onAppSelected: (InstalledApp) -> Void

    @State private var apps: [InstalledApp] = []
    @State private var searchText: String = ""
    @State private var selectedFilter: AppFilter = .all
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    enum AppFilter: String, CaseIterable {
        case all = "All"
        case user = "User"
        case system = "System"
    }

    var filteredApps: [InstalledApp] {
        var result = apps

        switch selectedFilter {
        case .all:
            break
        case .user:
            result = result.filter { !$0.isSystemApp }
        case .system:
            result = result.filter { $0.isSystemApp }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText)
            }
        }

        // User apps first, then by name.
        return result.sorted { a, b in
            if a.isSystemApp != b.isSystemApp { return !a.isSystemApp }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .onAppear { loadApps() }
        .onChange(of: device) { _ in loadApps() }
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("按名称或 Bundle ID 搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(6)

            Picker("", selection: $selectedFilter) {
                ForEach(AppFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("加载 App 列表...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            Text(error)
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredApps.isEmpty {
            Text(apps.isEmpty ? "没有找到 App" : "没有匹配的 App")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredApps) { app in
                AppRow(app: app)
                    .contentShape(Rectangle())
                    .onTapGesture { onAppSelected(app) }
            }
            .listStyle(.plain)
        }
    }

    private func loadApps() {
        guard let device = device else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
            let connected = DeviceManager.shared.connect(to: device)
            guard connected else {
                DispatchQueue.main.async {
                    self.errorMessage = "无法连接到设备"
                    self.isLoading = false
                }
                return
            }

            do {
                let lister = AppLister(device: device)
                let appList = try lister.listInstalledApps()
                DispatchQueue.main.async {
                    self.apps = appList
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - AppRow

struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconPlaceholder(app: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(app.version.isEmpty ? "—" : app.version)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                signingBadge
            }
        }
        .padding(.vertical, 3)
    }

    private var signingBadge: some View {
        let color = badgeColor
        return Text(app.badgeLabel)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var badgeColor: Color {
        if app.isSystemApp { return .gray }
        switch app.signingInfo {
        case .development: return .green
        case .distribution: return .blue
        case .enterprise: return .orange
        case .system: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - AppIconPlaceholder

// Real iOS app icons live inside the .app bundle which house_arrest doesn't
// expose. Until/unless we add network-based icon fetching (iTunes Search API
// for App Store apps, etc.), this gives a polished color-coded placeholder
// keyed off the bundle ID hash.
struct AppIconPlaceholder: View {
    let app: InstalledApp

    var body: some View {
        let colors = gradient(for: app.bundleID)
        RoundedRectangle(cornerRadius: 9)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 38, height: 38)
            .overlay(
                Text(initial)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            )
            .shadow(color: colors.last!.opacity(0.25), radius: 1, y: 1)
    }

    private var initial: String {
        // For system apps where name often starts with com.apple., prefer
        // something more visually distinct.
        let source = app.name.isEmpty ? app.bundleID : app.name
        // First non-whitespace character
        guard let firstChar = source.first(where: { !$0.isWhitespace }) else {
            return "?"
        }
        return String(firstChar).uppercased()
    }

    private func gradient(for key: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.30, green: 0.60, blue: 0.95), Color(red: 0.20, green: 0.40, blue: 0.85)],  // blue
            [Color(red: 0.40, green: 0.75, blue: 0.50), Color(red: 0.25, green: 0.60, blue: 0.35)],  // green
            [Color(red: 0.95, green: 0.55, blue: 0.30), Color(red: 0.85, green: 0.40, blue: 0.20)],  // orange
            [Color(red: 0.75, green: 0.40, blue: 0.85), Color(red: 0.55, green: 0.25, blue: 0.75)],  // purple
            [Color(red: 0.95, green: 0.40, blue: 0.55), Color(red: 0.80, green: 0.25, blue: 0.45)],  // pink
            [Color(red: 0.35, green: 0.70, blue: 0.75), Color(red: 0.20, green: 0.55, blue: 0.65)],  // teal
            [Color(red: 0.55, green: 0.50, blue: 0.85), Color(red: 0.40, green: 0.35, blue: 0.75)],  // indigo
            [Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.85, green: 0.60, blue: 0.20)],  // amber
        ]
        var hash: UInt32 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return palettes[Int(hash) % palettes.count]
    }
}
