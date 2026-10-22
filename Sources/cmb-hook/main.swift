import Foundation
import HookBridge

/// Claude Code hook entry point. Stdout stays empty: several hook events
/// treat stdout as context or as a permission decision.
@main
enum CMBHook {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let support = TidepoolPaths.supportDirectory()
        if arguments.first == "statusline" {
            let code = runStatusline(input: input, support: support)
            exit(code)
        }
        _ = ingestHook(input: input, support: support)
        exit(0)
    }
}

func ingestHook(input: Data, support: URL, now: Date = Date()) -> HookEvent? {
    guard let event = HookIngest.event(from: input, now: now) else { return nil }
    let log = EventLog(fileURL: TidepoolPaths.eventsFile(support: support))
    try? log.append(event)
    return event
}

func runStatusline(input: Data, support: URL, now: Date = Date()) -> Int32 {
    if let snapshot = StatuslineSnapshot.parse(input, capturedAt: now),
       snapshot.fiveHour != nil || snapshot.sevenDay != nil {
        try? snapshot.write(to: TidepoolPaths.statuslineFile(support: support))
    }
    let chain = StatuslineChain.load(from: TidepoolPaths.statuslineChainFile(support: support))
    let command = chain?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !command.isEmpty else { return 0 }
    return forward(input: input, shellCommand: command)
}

func forward(input: Data, shellCommand: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", shellCommand]
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        return 0
    }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    FileHandle.standardOutput.write(output)
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    FileHandle.standardError.write(errorData)
    return process.terminationStatus
}
