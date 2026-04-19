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
        case development = "Development"
        case distribution = "Distribution"
        case system = "System"
    }

    var filteredApps: [InstalledApp] {
        var result = apps

        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .development:
            result = result.filter { $0.signingInfo == .development }
        case .distribution:
            result = result.filter { $0.signingInfo == .distribution || $0.signingInfo == .enterprise }
        case .system:
            result = result.filter { $0.isSystemApp }
        }

        // Apply search
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar and filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search by name or bundle ID", text: $searchText)
                    .textFieldStyle(.plain)

                Picker("Filter", selection: $selectedFilter) {
                    ForEach(AppFilter.allCases, id: \.rawValue) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding()

            Divider()

            // App list
            if isLoading {
                ProgressView("Loading apps...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps, selection: Binding<InstalledApp?>(
                    get: { nil },
                    set: { app in
                        if let app = app {
                            onAppSelected(app)
                        }
                    }
                )) { app in
                    AppRow(app: app)
                        .tag(app)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            loadApps()
        }
        .onChange(of: device) { _ in
            loadApps()
        }
    }

    private func loadApps() {
        guard let device = device else { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global().async {
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

struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack {
            // App icon placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(app.name.prefix(1)))
                        .font(.title2)
                        .foregroundColor(.primary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(app.version)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(app.signingInfo.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(signingInfoColor(app.signingInfo).opacity(0.2))
                    .foregroundColor(signingInfoColor(app.signingInfo))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }

    private func signingInfoColor(_ info: InstalledApp.SigningInfo) -> Color {
        switch info {
        case .development: return .green
        case .distribution: return .blue
        case .enterprise: return .orange
        case .unknown: return .gray
        }
    }
}