//
//  ResignTask.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import Foundation

/// 重签名工具类
struct ResignTask {
    let taskInfo: ResignTaskInfo
    let workspacePath: URL
    let logger: LoggerProtocol?
    
    init(taskInfo: ResignTaskInfo, logger: LoggerProtocol?) throws {
        self.taskInfo = taskInfo
        self.logger = logger
        /// 创建工作区
        workspacePath = try PathManager.getCacheDir().appendingPathComponent("ResignTask").appendingPathComponent(Date.now.formatString(format: "yyyyMMddHHmmssSSS"))
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true, attributes: nil)
        logger?.log(.INFO, "工作区目录：\(workspacePath.path)")
    }
    
    
    func Start() throws {
        defer {
            logger?.log(.INFO, "清理工作区目录：\(workspacePath.path)")
            try? FileManager.default.removeItem(at: workspacePath)
        }

        logger?.log(.INFO, "签名后端：\(taskInfo.backend.displayName)")
        switch taskInfo.backend {
        case .zsign:
            try startZSignResign()
        case .apple:
            try startAppleResign()
        }
    }

    private func startAppleResign() throws {
        let appBundle = try getAppBundle()
        
        logger?.log(.INFO, "开始重签名...")
        
        logger?.log(.INFO, "修改包体信息...")
        try appBundle.update(bundleId: taskInfo.bundleId, displayName: taskInfo.displayName, version: taskInfo.version, buildVersion: taskInfo.buildVersion)
        
        logger?.log(.INFO, "包体信息：")
        logger?.log(.INFO, """
        Bundle ID: \(appBundle.bundleId)
        应用名称：\(appBundle.displayName)
        外置版本号：\(appBundle.version)
        内置版本号：\(appBundle.buildVersion)
        """)
        
        logger?.log(.INFO, "删除包体内无用文件...")
        try TaskCenter.executeShell(command: "find -d \"\(appBundle.path.path)\" -name \".DS_Store\" -o -name \"__MACOSX\" | xargs rm -rf")
        
        logger?.log(.INFO, "安装 App p12 文件...")
        let pkcs12 = try PKCS12(file: taskInfo.p12Path, password: taskInfo.p12Password)
        logger?.log(.INFO, "App 证书名称：\(pkcs12.certificate.commonName) Sha1：\(pkcs12.certificate.sha1.hexString)")

        logger?.log(.INFO, "安装 App 描述文件...")
        guard let mobileProvision = try MobileProvision(file: taskInfo.mobileProvisionPath) else {
            throw NSError.init(message: "读取 App 描述文件异常")
        }
        try mobileProvision.install()
        logger?.log(.INFO, "App 描述文件名称：\(mobileProvision.name), Team ID: \(mobileProvision.teamId)")

        logger?.log(.INFO, "注入动态库...")
        try injectDylibsForApple(appBundle: appBundle)
        
        logger?.log(.INFO, "重签动态库...")
        try codesignDynamicLibrary(appBundle: appBundle, pkcs12: pkcs12)
        
        logger?.log(.INFO, "重签 Appex...")
        let appexResignReuslt = try codesignAppex(appBundle: appBundle, pkcs12: pkcs12, mobileProvision: mobileProvision, logger: logger)
        
        logger?.log(.INFO, "替换 entitlements..")
        let newEntitlements = try updateEntitlements(appBundle: appBundle, mobileProvision: mobileProvision, logger: logger)
        
        logger?.log(.INFO, "重签 App...")
        try codesignApp(appBundle: appBundle, pkcs12: pkcs12, entitlements: newEntitlements)
        
        /// 复制 xcarchive 模板到工作区
        logger?.log(.INFO, "复制 xcarchive 模板到工作区...")
        let archiveTemplate = try createArchiveTemplate(appBundle: appBundle, pkcs12: pkcs12, mobileProvision: mobileProvision, appexResignInfo: appexResignReuslt, logger: logger)
        
        logger?.log(.INFO, "执行 xcodebuild exportArchive...")
        let ipaPath = try xcodebuildExportArchive(xcarchivePath: archiveTemplate.xcarchivePath, exportOptionsPlistPath: archiveTemplate.exportOptionsPlistPath)
        
        logger?.log(.INFO, "复制 ipa...")
        if FileManager.default.fileExists(atPath: taskInfo.outputPath.path) {
            try FileManager.default.removeItem(at: taskInfo.outputPath)
        }
        try FileManager.default.copyItem(at: ipaPath, to: taskInfo.outputPath)
        
        logger?.log(.INFO, "重签名完成🎉🎉🎉")
    }

    private func startZSignResign() throws {
        let appBundle = try getAppBundle()

        logger?.log(.INFO, "开始 zsign 重签名...")

        logger?.log(.INFO, "修改包体信息...")
        try appBundle.update(bundleId: taskInfo.bundleId, displayName: taskInfo.displayName, version: taskInfo.version, buildVersion: taskInfo.buildVersion)

        logger?.log(.INFO, "包体信息：")
        logger?.log(.INFO, """
        Bundle ID: \(appBundle.bundleId)
        应用名称：\(appBundle.displayName)
        外置版本号：\(appBundle.version)
        内置版本号：\(appBundle.buildVersion)
        """)

        if !appBundle.appexList.isEmpty {
            logger?.log(.INFO, "zsign 将使用主 App 证书和描述文件递归重签 Appex：\(appBundle.appexList.map { $0.path.lastPathComponent }.joined(separator: ", "))")
        }

        logger?.log(.INFO, "删除包体内无用文件...")
        try TaskCenter.executeShell(command: "find -d \"\(appBundle.path.path)\" -name \".DS_Store\" -o -name \"__MACOSX\" | xargs rm -rf")

        let injectedDylibs = try validatedInjectedDylibs()
        if !injectedDylibs.isEmpty {
            logger?.log(.INFO, "zsign 将注入动态库：\(injectedDylibs.map { $0.lastPathComponent }.joined(separator: ", "))")
        }

        logger?.log(.INFO, "读取 App 描述文件...")
        guard let mobileProvision = try MobileProvision(file: taskInfo.mobileProvisionPath) else {
            throw NSError.init(message: "读取 App 描述文件异常")
        }
        logger?.log(.INFO, "App 描述文件名称：\(mobileProvision.name), Team ID: \(mobileProvision.teamId)")

        logger?.log(.INFO, "生成 zsign entitlements...")
        let newEntitlements = try updateEntitlements(appBundle: appBundle, mobileProvision: mobileProvision, logger: logger)
        let entitlementsPath = workspacePath.appendingPathComponent("zsign.entitlements")
        try newEntitlements.write(to: entitlementsPath, atomically: true, encoding: .utf8)

        let options = ZSignBridgeOptions()
        options.inputPath = appBundle.path.path
        options.p12Path = taskInfo.p12Path.path
        options.p12Password = taskInfo.p12Password
        options.mobileProvisionPath = taskInfo.mobileProvisionPath.path
        options.entitlementsPath = entitlementsPath.path
        options.outputPath = taskInfo.outputPath.path
        options.temporaryDirectory = workspacePath.path
        options.injectedDylibPaths = injectedDylibs.map { $0.path }
        options.weakInject = false
        options.zipLevel = 0
        options.logHandler = { [logger] level, message in
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return
            }
            logger?.log(level == 1 ? .ERROR : .INFO, text)
        }

        logger?.log(.INFO, "执行 zsign 签名和打包...")
        try ZSignBridge.resign(with: options)

        logger?.log(.INFO, "输出 ipa：\(taskInfo.outputPath.path)")
        logger?.log(.INFO, "重签名完成🎉🎉🎉")
    }
}



extension ResignTask {
    
    private func getAppBundle() throws -> AppBundle {
        if taskInfo.filePath.pathExtension == "ipa" || taskInfo.filePath.pathExtension == "zip" {
            let outputPath = workspacePath.appendingPathComponent("ipa_content")
            let command = "unzip \"\(taskInfo.filePath.path)\" -d \"\(outputPath.path)\""
            try TaskCenter.executeShell(command: command)
            let payloadPath = outputPath.appendingPathComponent("Payload")
            guard let appPath = try FileManager.default.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles).first(where: { $0.pathExtension == "app" }) else {
                throw NSError(message: "非法文件，找不到 app")
            }
            return try AppBundle(path: appPath)
        } else if taskInfo.filePath.pathExtension == "app" {
            let outputPath = workspacePath.appendingPathComponent("app_content")
            try FileManager.default.createDirectory(at: outputPath, withIntermediateDirectories: true)
            let appPath = outputPath.appendingPathComponent(taskInfo.filePath.lastPathComponent)
            try FileManager.default.copyItem(at: taskInfo.filePath, to: appPath)
            return try AppBundle(path: appPath)
        } else {
            throw NSError(message: "非法文件")
        }
    }
    
    /// 查找.app路径
    /// - Parameter directory: 文件夹
    /// - Returns: app路径
    private func findAppPath(directory: URL) throws -> URL {
        let output = try TaskCenter.executeShell(command: "find -d \"\(directory.path)\" -maxdepth 3 -name  \"*.app\" | head -n 1")
        return URL(fileURLWithPath: output.trimmingCharacters(in: .newlines))
    }
    
    /// 重签 Appex
    /// - Parameters:
    ///   - pkcs12: 主 App 证书
    ///   - mobileProvision: 主 App 描述文件
    ///   - logger: 日志
    /// - Returns: 重签结果
    private func codesignAppex(appBundle: AppBundle, pkcs12: PKCS12, mobileProvision: MobileProvision, logger: LoggerProtocol?) throws -> [(bundleId: String, mobileProvision: MobileProvision)] {
        guard !appBundle.appexList.isEmpty else {
            logger?.log(.INFO, "未发现 Appex，跳过")
            return []
        }

        var appexResignReuslt: [(bundleId: String, mobileProvision: MobileProvision)] = []
        try appBundle.appexList.forEach { appex in
            let name = appex.path.lastPathComponent
            logger?.log(.INFO, "使用主 App 证书重签 \(name)...")
            let cmd = "/usr/bin/codesign -vvv --continue -f -s \"\(pkcs12.certificate.sha1.hexString)\"  --generate-entitlement-der --preserve-metadata=identifier,flags,runtime \"\(appex.path.path)\""
            try TaskCenter.executeShell(command: cmd)
            
            appexResignReuslt.append((bundleId: appex.bundleId, mobileProvision: mobileProvision))
        }
        return appexResignReuslt
    }
    
    
    /// 重签动态库
    /// - Parameters:
    ///   - appPath: app路径
    ///   - identity: 证书
    private func codesignDynamicLibrary(appBundle: AppBundle, pkcs12: PKCS12) throws {
        let cmd = "find -d \"\(appBundle.path.path)\" -name \"*.dylib\" -o -name \"*.framework\""
        let result = try TaskCenter.executeShell(command: cmd)
        try result.components(separatedBy: "\n").forEach { item  in
            if !item.isEmpty {
                let cmd = "/usr/bin/codesign -vvv --continue -f -s \"\(pkcs12.certificate.sha1.hexString)\"  --generate-entitlement-der --preserve-metadata=identifier,flags,runtime \"\(item)\""
                try TaskCenter.executeShell(command: cmd)
            }
        }
    }

    private func validatedInjectedDylibs() throws -> [URL] {
        let dylibURLs = taskInfo.injectedDylibPaths
        guard !dylibURLs.isEmpty else {
            return []
        }

        let duplicateFileNames = DylibInjection.duplicateFileNames(in: dylibURLs)
        if !duplicateFileNames.isEmpty {
            throw NSError(message: "注入动态库存在同名文件：\(duplicateFileNames.joined(separator: ", "))")
        }

        for dylibURL in dylibURLs {
            if !FileManager.default.fileExists(atPath: dylibURL.path) {
                throw NSError(message: "注入动态库不存在：\(dylibURL.path)")
            }
            if dylibURL.pathExtension.lowercased() != "dylib" {
                throw NSError(message: "注入文件不是 dylib：\(dylibURL.path)")
            }
        }

        return dylibURLs
    }

    private func injectDylibsForApple(appBundle: AppBundle) throws {
        let dylibURLs = try validatedInjectedDylibs()
        guard !dylibURLs.isEmpty else {
            logger?.log(.INFO, "未选择动态库，跳过注入")
            return
        }

        guard let executablePath = appBundle.executableFilePath else {
            throw NSError(message: "找不到 App 主可执行文件")
        }
        var loadCommandNames: [String] = []
        for dylibURL in dylibURLs {
            let targetURL = appBundle.path.appendingPathComponent(dylibURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: dylibURL, to: targetURL)

            let loadCommandName = DylibInjection.loadCommandName(for: dylibURL)
            logger?.log(.INFO, "注入动态库：\(loadCommandName)")
            loadCommandNames.append(loadCommandName)
        }

        try ZSignBridge.injectDylibs(loadCommandNames, intoExecutable: executablePath.path, weakInject: false)
    }
    
    /// 重签 App
    /// - Parameters:
    ///   - workspacePath: 工作区
    ///   - appPath: app路径
    ///   - certificateSha1: 证书指纹
    ///   - entitlements: 权力字
    private func codesignApp(appBundle: AppBundle, pkcs12: PKCS12, entitlements: String) throws {
        let entitlementsPath = workspacePath.appendingPathComponent("temp.entitlements")
        FileManager.default.createFile(atPath: entitlementsPath.path, contents: entitlements.data(using: .utf8))
        try TaskCenter.executeShell(command: "/usr/bin/codesign -vvv -f -s \"\(pkcs12.certificate.sha1.hexString)\" --entitlements \"\(entitlementsPath.path)\" --generate-entitlement-der \"\(appBundle.path.path)\"")
    }
    
    
    private func createArchiveTemplate(
        appBundle: AppBundle,
        pkcs12: PKCS12,
        mobileProvision: MobileProvision,
        appexResignInfo: [(bundleId: String, mobileProvision: MobileProvision)],
        logger: LoggerProtocol?
    ) throws -> (xcarchivePath: URL, exportOptionsPlistPath: URL) {
        /// 复制 xcarchive 模板到工作区
        logger?.log(.INFO, "复制 xcarchive 模板到工作区...")
        let templatePath = workspacePath.appendingPathComponent("template")
        guard let resignTemplate = Bundle.main.resourceURL?.appendingPathComponent("Resources/resign_template") else {
            throw NSError(message: "找不到重签模板")
        }
        try FileManager.default.copyItem(at: resignTemplate, to: templatePath)

        logger?.log(.INFO, "修改 xcarchive 模板内容...")
        let xcarchivePath = templatePath.appendingPathComponent("payload.xcarchive")
        let xcarchiveInfoPlistPath = xcarchivePath.appendingPathComponent("Info.plist")
        let exportOptionsPlistPath = templatePath.appendingPathComponent("ExportOptions.plist")
        
        /// 复制 app 到 xcarchive 内
        let xcarchiveAppDir = xcarchivePath.appendingPathComponent("Products/Applications")
        if !FileManager.default.fileExists(atPath: xcarchiveAppDir.path) {
            try FileManager.default.createDirectory(at: xcarchiveAppDir, withIntermediateDirectories: true, attributes: nil)
        }
        try FileManager.default.copyItem(at: appBundle.path, to: xcarchiveAppDir.appendingPathComponent(appBundle.path.lastPathComponent))
        
        /// 更新 xcarchive Info.plist
        updatePlist(url: xcarchiveInfoPlistPath) { info in
            info["Name"] = appBundle.path.deletingPathExtension().lastPathComponent
            info["SchemeName"] = appBundle.path.deletingPathExtension().lastPathComponent
            if var applicationProperties = info["ApplicationProperties"] as? [String: Any] {
                applicationProperties["ApplicationPath"] = "Applications/\(appBundle.path.lastPathComponent)"
                applicationProperties["CFBundleIdentifier"] = appBundle.bundleId
                applicationProperties["CFBundleShortVersionString"] = appBundle.version
                applicationProperties["CFBundleVersion"] = appBundle.buildVersion
                applicationProperties["SigningIdentity"] = pkcs12.certificate.sha1.hexString
                applicationProperties["Team"] = mobileProvision.teamId
                info["ApplicationProperties"] = applicationProperties
            }
        }
        
        /// 更新 export options plist
        updatePlist(url: exportOptionsPlistPath) { info in
            info["signingCertificate"] = pkcs12.certificate.sha1.hexString
            info["method"] = taskInfo.exportType.rawValue // app-store, ad-hoc, enterprise, development, validation 5种类型
            info["teamID"] = mobileProvision.teamId
            
            var provisioningProfiles = [String: String]()
            provisioningProfiles[appBundle.bundleId] = mobileProvision.uuid
            for item in appexResignInfo {
                provisioningProfiles[item.bundleId] = item.mobileProvision.uuid
            }
            info["provisioningProfiles"] = provisioningProfiles
        }
        
        return (xcarchivePath, exportOptionsPlistPath)
    }
    
    /// 执行xcodebuild的导出Archive操作
    /// - Parameters:
    ///   - xcarchivePath: .xcarchive 路径
    ///   - exportPath: 导出目录
    ///   - exportOptionsPlist: exportOptionsPlist 路径
    /// - Returns: ipa 路径
    private func xcodebuildExportArchive(xcarchivePath: URL, exportOptionsPlistPath: URL) throws -> URL {
        let exportDirPath = workspacePath.appendingPathComponent("export")
        let cmd = "xcodebuild -exportArchive -archivePath \"\(xcarchivePath.path)\" -exportPath \"\(exportDirPath.path)\"  -exportOptionsPlist \"\(exportOptionsPlistPath.path)\""
        try TaskCenter.executeShell(command: cmd)
        guard let ipaPath = try FileManager.default.contentsOfDirectory(at: exportDirPath, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles).first(where: { $0.pathExtension == "ipa" }) else {
            throw NSError(message: "导出 ipa 失败")
        }
        return ipaPath
    }
    
    private func updateEntitlements(appBundle: AppBundle, mobileProvision: MobileProvision, logger: LoggerProtocol?) throws -> String {
        var newEntitlements: [String: Any]
        if let newEntitlementsString = taskInfo.entitlements,
           !newEntitlementsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger?.log(.INFO, "解析自定义 entitlements...")
            guard let data = newEntitlementsString.data(using: .utf8),
                  let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw NSError(message: "新 entitlements 格式异常")
            }
            newEntitlements = dict
            logger?.log(.INFO, "自定义 entitlements：\(newEntitlements.toPlist())")
        } else {
            do {
                newEntitlements = try appBundle.getEntitlements()
                logger?.log(.INFO, "原 entitlements：\(newEntitlements.toPlist())")
            } catch {
                logger?.log(.INFO, "读取原 entitlements 失败，改用描述文件 entitlements 作为基底：\(error.localizedDescription)")
                newEntitlements = mobileProvision.entitlements
                logger?.log(.INFO, "描述文件 entitlements：\(newEntitlements.toPlist())")
            }
        }
        
        newEntitlements["application-identifier"] = "\(mobileProvision.teamId).\(appBundle.bundleId)"
        newEntitlements["com.apple.developer.team-identifier"] = mobileProvision.teamId
        
        // 特殊处理
        switch taskInfo.exportType {
        case .appStore:
            newEntitlements["get-task-allow"] = false
            newEntitlements["beta-reports-active"] = true
        case .dev:
            newEntitlements["get-task-allow"] = true
            newEntitlements.removeValue(forKey: "beta-reports-active")
        case .adHoc:
            newEntitlements["get-task-allow"] = true
            newEntitlements["beta-reports-active"] = true
        case .enterprise:
            newEntitlements["get-task-allow"] = true
            newEntitlements["beta-reports-active"] = true
        case .validation:
            newEntitlements["get-task-allow"] = true
            newEntitlements["beta-reports-active"] = true
        }
        
        // 去除证书不存在的
        newEntitlements = newEntitlements.filter { item in
            if !mobileProvision.entitlements.contains(where: { $0.key == item.key }) {
                return false
            }
            if ["com.apple.developer.ubiquity-kvstore-identifier",
                "com.apple.developer.ubiquity-container-identifiers"].contains(item.key) {
                return mobileProvision.entitlements.contains{ $0.key == "com.apple.developer.icloud-container-environment" }
            }
            return true
        }
        
        logger?.log(.INFO, "新 entitlements：\(newEntitlements.toPlist())")
        
        let data = try PropertyListSerialization.data(fromPropertyList: newEntitlements, format: .xml, options: 0)
        guard let result = String(data: data, encoding: .utf8) else {
            throw NSError(message: "生成 entitlements 异常")
        }
        
        return result
    }
}


private extension ResignTask {
    
    /// 更新plist文件
    ///
    /// - Parameters:
    ///   - url: plist文件路径
    ///   - block: 用于修改plist的闭包
    ///
    func updatePlist(url: URL, block: (NSMutableDictionary) -> Void) {
        if let info = NSMutableDictionary(contentsOf: url) {
            block(info)
            info.write(to: url, atomically: true)
        }
    }
}

fileprivate extension Dictionary {
    func toPlist() -> String {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
            let str = String(data: data, encoding: .utf8) ?? ""
            return str
        } catch {
            print("Error: \(error)")
        }
        return ""
    }
}
