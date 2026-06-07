//
//  TaskCenter.swift
//  EasySign
//
//  Created by crazyball on 2024/7/13.
//

import Foundation

/// 执行任务失败错误
struct TaskError: LocalizedError {
    var code: Int32
    var output: String
    
    var errorDescription: String? {
        "\(code) \(output)"
    }
}

/// 任务执行中心
class TaskCenter {
    /// 任务完成回调函数
    typealias TaskCompleteHandler = (Result<String, TaskError>) -> Void
    
    /// 同步执行
    /// - Parameters:
    ///   - launchPath: 任务可执行文件路径
    ///   - arguments: 任务执行的参数
    ///   - workingDirectory: 任务执行的目录
    /// - Returns: 任务执行结果
    @discardableResult
    static func execute(lanuchPath: String, arguments: [String]? = nil, workingDirectory: URL? = nil) throws -> String {
        let task = Process()
        task.launchPath = lanuchPath
        task.arguments = arguments
        task.currentDirectoryURL = workingDirectory
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        task.launch()
        // 先把管道读空、再 waitUntilExit:子进程输出超过管道缓冲(~64KB)时,
        // 若先 wait 会与子进程阻塞的 write 形成死锁(大输出命令如 unzip 大包必现)。
        // readDataToEndOfFile 会持续排空管道直到子进程退出关闭写端(EOF)。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        
        if task.terminationStatus != 0 {
            throw TaskError(code: task.terminationStatus, output: output)
        }
        
        return output
    }
    
    /// 同步执行 Shell
    /// - Parameters:
    ///   - command: shell 命令
    ///   - workingDirectory: 命令执行的目录
    /// - Returns: 命令执行结果
    @discardableResult
    static func executeShell(command: String, workingDirectory: URL? = nil) throws -> String {
        return try execute(lanuchPath: "/bin/sh", arguments: ["-c", command], workingDirectory: workingDirectory)
    }
    
    /// 异步执行任务
    /// - Parameters:
    ///   - launchPath: 任务可执行文件路径
    ///   - arguments: 任务执行的参数
    ///   - workingDirectory: 任务执行的目录
    ///   - completeHandler: 任务完成回调函数
    static func executeAsync(lanuchPath: String, arguments: [String]? = nil, workingDirectory: URL? = nil, completeHandler: TaskCompleteHandler?) {
        let originQueue = OperationQueue.current
        
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = lanuchPath
            task.arguments = arguments
            task.currentDirectoryURL = workingDirectory
            task.standardInput = FileHandle.nullDevice
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            pipe.fileHandleForReading.waitForDataInBackgroundAndNotify()

            var terminationObs: NSObjectProtocol?
            terminationObs = NotificationCenter.default.addObserver(forName: Process.didTerminateNotification, object: task, queue: OperationQueue.current, using: { notification in
                NotificationCenter.default.removeObserver(terminationObs!)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                pipe.fileHandleForReading.closeFile()
                
                originQueue?.addOperation {
                    if task.terminationStatus == 0 {
                        completeHandler?(.success(output))
                    } else {
                        completeHandler?(.failure(.init(code: task.terminationStatus, output: output)))
                    }
                }
            })
            task.launch()
            task.waitUntilExit()
        }
    }
    
    /// 异步执行 Shell 命令
    /// - Parameters:
    ///   - command: shell 命令
    ///   - workingDirectory: 命令执行的目录
    ///   - completeHandler: 任务完成回调函数
    static func executeShellAsync(command: String, workingDirectory: URL? = nil, completeHandler: TaskCompleteHandler?) {
        return executeAsync(lanuchPath: "/bin/sh", arguments: ["-c", command], workingDirectory: workingDirectory, completeHandler: completeHandler)
    }
    
}


