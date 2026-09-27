import Foundation

public enum Shell {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Run an executable, return stdout. Throws with stderr on non-zero exit.
    /// On timeout or task cancellation the process *and its children* (e.g. zsh → npx → node) are terminated.
    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil, timeout: Double = 60) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        p.standardInput = FileHandle.nullDevice
        let timedOut = OnceFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let lock = NSLock()
                nonisolated(unsafe) var outData = Data(), errData = Data()
                // Empty data = EOF; Foundation keeps calling the handler after that, so detach it or it spins a core.
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { lock.withLock { outData.append(d) } }
                }
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { lock.withLock { errData.append(d) } }
                }
                p.terminationHandler = { proc in
                    // Brief grace period for the last buffered bytes; never block on EOF (a grandchild may hold the pipe).
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        let (o, e) = lock.withLock { (outData, errData) }
                        if !timedOut.claim() {
                            cont.resume(throwing: Failure(message: "\(URL(fileURLWithPath: exe).lastPathComponent) timed out after \(Int(timeout))s"))
                        } else if proc.terminationStatus == 0 {
                            cont.resume(returning: String(decoding: o, as: UTF8.self))
                        } else {
                            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                            cont.resume(throwing: Failure(message: msg.isEmpty ? "\(exe) exited \(proc.terminationStatus)" : String(msg.prefix(2000))))
                        }
                    }
                }
                do { try p.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard p.isRunning, timedOut.claim() else { return }
                    killTree(p)
                }
            }
        } onCancel: {
            killTree(p)
        }
    }

    /// SIGTERM the process's children first, then the process itself. Signals directly (no `pkill` subprocess):
    /// spawning and waiting on a helper here could block, and this runs from timeouts and cancellation.
    static func killTree(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        var kids = [pid_t](repeating: 0, count: 256)
        let n = kids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        for child in kids.prefix(max(0, Int(n))) where child > 0 { kill(child, SIGTERM) }
        p.terminate()
    }

    /// Run AppleScript with arguments passed as `argv` (never string-interpolated → no injection).
    @discardableResult
    public static func appleScript(_ source: String, _ args: [String] = [], timeout: Double = 30) async throws -> String {
        do {
            return try await run("/usr/bin/osascript", ["-e", source] + args, timeout: timeout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let f as Failure where f.message.contains("-1743") || f.message.contains("Not authorized") {
            throw Failure(message: "macOS blocked automation. Allow Paluku in System Settings › Privacy & Security › Automation.")
        }
    }

    /// Run a command line through the user's login shell so PATH (nvm, uvx, homebrew) resolves like in Terminal.
    public static func loginShell(_ command: String, cwd: URL? = nil, timeout: Double = 600) async throws -> String {
        try await run("/bin/zsh", ["-lc", command], cwd: cwd, timeout: timeout)
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
