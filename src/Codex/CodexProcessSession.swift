import Foundation

final class ProcessCodexSession: CodexStdioSession, @unchecked Sendable {
    var outputHandler: ((Data) -> Void)?
    var exitHandler: ((Int32) -> Void)?

    private let executable: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var started = false
    private var inputClosed = false

    init(executable: String) {
        self.executable = executable
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else {
            return
        }
        started = true
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.outputHandler?(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.exitHandler?(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw CodexFailure.transportStart
        }
    }

    func send(_ data: Data) {
        lock.lock()
        let closed = inputClosed
        lock.unlock()
        guard !closed else {
            return
        }
        stdinPipe.fileHandleForWriting.write(data)
    }

    func closeInput() {
        lock.lock()
        guard !inputClosed else {
            lock.unlock()
            return
        }
        inputClosed = true
        lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
    }

    func abort() {
        lock.lock()
        inputClosed = true
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        try? stdinPipe.fileHandleForWriting.close()
    }
}

struct ProcessCodexSessionFactory: CodexSessionFactory {
    func openAppServer(executable: String) throws -> CodexStdioSession {
        ProcessCodexSession(executable: executable)
    }
}

enum CodexVersionProbe {
    static func run(executable: String) -> Result<String, CodexFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(.transportStart)
        }
        process.waitUntilExit()
        _ = try? stderr.fileHandleForReading.readToEnd()
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        guard let output = String(data: data, encoding: .utf8) else {
            return .failure(.versionTooOld)
        }
        return .success(output)
    }
}
