import Foundation

final class FileTransfer {
    private let afcClient: AFCClient

    init(afcClient: AFCClient) {
        self.afcClient = afcClient
    }

    // MARK: - Download

    func downloadFile(remotePath: String, to localURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let fileData = try afcClient.readFile(at: remotePath)
        try fileData.write(to: localURL)
    }

    func downloadDirectory(remotePath: String, to localURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let fileNodes = try afcClient.listDirectory(at: remotePath)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        for node in fileNodes where node.name != "." && node.name != ".." {
            let destPath = localURL.appendingPathComponent(node.name)
            if node.isDirectory {
                try downloadDirectory(remotePath: node.path, to: destPath, progress: progress)
            } else {
                try downloadFile(remotePath: node.path, to: destPath, progress: progress)
            }
        }
    }

    // MARK: - Upload

    func uploadFile(localURL: URL, to remotePath: String, progress: ((Double) -> Void)? = nil) throws {
        let data = try Data(contentsOf: localURL)
        try afcClient.writeFile(at: remotePath, data: data)
    }

    func uploadDirectory(localURL: URL, to remotePath: String, progress: ((Double) -> Void)? = nil) throws {
        try afcClient.createDirectory(at: remotePath)

        let contents = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)
        for item in contents {
            let itemName = item.lastPathComponent
            let destPath = (remotePath as NSString).appendingPathComponent(itemName)

            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)

            if isDir.boolValue {
                try uploadDirectory(localURL: item, to: destPath, progress: progress)
            } else {
                try uploadFile(localURL: item, to: destPath, progress: progress)
            }
        }
    }
}
