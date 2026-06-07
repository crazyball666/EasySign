import Foundation
import AppKit

/// 应用内更新:检查 GitHub 最新 Release、下载 .dmg、去 quarantine、挂载。
final class UpdateService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let repo = "crazyball666/EasySign"

    @Published var availableUpdate: UpdateInfo?
    @Published var downloadProgress: Double?     // 0...1 下载中,否则 nil
    @Published var isChecking = false
    @Published var lastCheckError: String?
    @Published var upToDateNotice = false         // 手动检查且已是最新 → true(UI 弹一下)
    @Published var installerOpened = false        // dmg 已挂载打开 → true

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "update.lastCheckAt"
    private let autoCheckKey = "update.autoCheckEnabled"
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var pendingVersion: String?           // captured on main before download starts

    let logger: LoggerService

    init(logger: LoggerService) {
        self.logger = logger
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: autoCheckKey) == nil ? true : defaults.bool(forKey: autoCheckKey) }
        set { defaults.set(newValue, forKey: autoCheckKey) }
    }

    private var currentVersion: SemanticVersion? {
        SemanticVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    /// 启动时调用:开关开 && 距上次检查 >24h 才静默检查。
    func maybeAutoCheckOnLaunch() {
        guard autoCheckEnabled else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkForUpdates(silent: true)
    }

    /// 检查更新。silent=true(自动):失败/无更新都不打扰。
    func checkForUpdates(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true
        lastCheckError = nil
        upToDateNotice = false
        installerOpened = false
        defaults.set(Date(), forKey: lastCheckKey)

        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("EasySign", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                if let err {
                    if !silent { self.lastCheckError = "检查失败:\(err.localizedDescription)" }
                    return
                }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    if !silent { self.lastCheckError = "检查失败:GitHub 返回 \(http.statusCode)" }
                    return
                }
                guard let data, let parsed = try? GitHubReleaseParser.parse(data) else {
                    if !silent { self.lastCheckError = "检查失败:无法解析响应" }
                    return
                }
                guard let latest = SemanticVersion(parsed.tagName), let current = self.currentVersion else {
                    if !silent { self.lastCheckError = "检查失败:版本号无法解析" }
                    return
                }
                guard latest.isNewer(than: current), let dmg = parsed.dmgURL else {
                    if !silent { self.upToDateNotice = true }   // 已是最新
                    return
                }
                self.availableUpdate = UpdateInfo(version: latest.displayString,
                                                  releaseNotes: parsed.body,
                                                  dmgURL: dmg, publishedAt: parsed.publishedAt)
                self.logger.log(.info, tool: "update", "发现新版本 \(latest.displayString)")
            }
        }.resume()
    }

    /// 下载当前 availableUpdate 的 .dmg。
    func startDownload() {
        guard let update = availableUpdate, downloadTask == nil else { return }
        installerOpened = false
        pendingVersion = update.version
        downloadProgress = 0
        let task = session.downloadTask(with: update.dmgURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
    }

    func dismissUpdate() { availableUpdate = nil; installerOpened = false }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.downloadProgress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let version = pendingVersion ?? "latest"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = downloads.appendingPathComponent("EasySign-\(version).dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async {
                self.lastCheckError = "保存失败:\(error.localizedDescription)"
                self.downloadProgress = nil; self.downloadTask = nil
            }
            return
        }
        stripQuarantine(dest)
        DispatchQueue.main.async {
            self.downloadProgress = nil
            self.downloadTask = nil
            NSWorkspace.shared.open(dest)        // 挂载 dmg,弹出拖拽窗口
            self.installerOpened = true
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.lastCheckError = "下载失败:\(error.localizedDescription)"
            self.downloadProgress = nil
            self.downloadTask = nil
        }
    }

    private func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", url.path]
        p.standardError = Pipe(); p.standardOutput = Pipe()
        try? p.run(); p.waitUntilExit()   // 失败(本就无此属性)无所谓
    }
}
