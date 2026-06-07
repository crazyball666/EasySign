//
//  IPA.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import Foundation

class IPA {
    private var file: URL
    let appBundle: AppBundle
    let workspace: URL
    
    init(file: URL) throws {
        self.file = file
        self.workspace = try PathManager.getTempWorkspace()
        // argv 形式(不经 shell):路径含 " $ ` 等字符也不会破损或被注入。
        try TaskCenter.execute(lanuchPath: "/usr/bin/unzip",
                               arguments: ["-o", "-q", file.path, "Payload/*.app/Info.plist",
                                           "-d", workspace.path, "-x", "*/.DS_Store"])
        let payloadPath = workspace.appendingPathComponent("Payload")
        guard let appPath = try FileManager.default.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles).first(where: { $0.pathExtension == "app" }) else {
            throw NSError(message: "非法文件，找不到 app")
        }
        appBundle = try AppBundle(path: appPath)
        
        // 解压主文件
        if let executableName = appBundle.executableName {
            try TaskCenter.execute(lanuchPath: "/usr/bin/unzip",
                                   arguments: ["-o", "-q", file.path,
                                               "Payload/\(appPath.lastPathComponent)/\(executableName)",
                                               "-d", workspace.path, "-x", "*/.DS_Store"])
        }
    }
    
    deinit {
        try? FileManager.default.removeItem(at: workspace)
    }
}
