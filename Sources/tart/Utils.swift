import Foundation

// A fire-and-forget task that reports any thrown error to stderr. An unstructured
// Task spawned from a synchronous context (a signal handler, a SwiftUI action) has
// no parent to propagate its error to, so we report it here instead of dropping it.
struct ErrorReportingTask {
  let task: Task<Void, Never>

  // Inherit the caller's actor context, exactly as Task.init does. Without this, an
  // operation written inside a @MainActor function runs on the cooperative pool
  // rather than the main queue, trapping in callees that assert their queue.
  @discardableResult
  init(_ context: String, @_inheritActorContext operation: @escaping @Sendable () async throws -> Void) {
    task = Task {
      do {
        try await operation()
      } catch {
        fputs("\(context): \(error)\n", stderr)
      }
    }
  }
}

extension Collection {
  subscript (safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

func resolveBinaryPath(_ name: String) -> URL? {
  guard let path = ProcessInfo.processInfo.environment["PATH"] else {
    return nil
  }

  for pathComponent in path.split(separator: ":") {
    let url = URL(fileURLWithPath: String(pathComponent))
      .appendingPathComponent(name, isDirectory: false)

    if FileManager.default.fileExists(atPath: url.path) {
      return url
    }
  }

  return nil
}

func runTool(_ name: String, _ arguments: [String]) throws -> (Data, Data) {
  guard let toolURL = resolveBinaryPath(name) else {
    throw RuntimeError.Generic("\"\(name)\" binary is not found in PATH")
  }

  let process = Process()
  process.executableURL = toolURL
  process.arguments = arguments

  let stdoutPipe = Pipe()
  process.standardOutput = stdoutPipe
  let stderrPipe = Pipe()
  process.standardError = stderrPipe

  let commandLine = ([name] + arguments).joined(separator: " ")

  do {
    try process.run()
  } catch {
    throw RuntimeError.Generic("\"\(commandLine)\" failed: \(error)")
  }

  // Drain both pipes while the tool runs, as it blocks once either pipe's buffer is full
  var stderrData = Data()
  let stderrDrained = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    stderrDrained.signal()
  }
  let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  stderrDrained.wait()
  process.waitUntilExit()

  if process.terminationStatus != 0 {
    let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

    throw RuntimeError.Generic("\"\(commandLine)\" failed with exit code \(process.terminationStatus): \(firstNonEmptyLine(stderrString, stdoutString))")
  }

  return (stdoutData, stderrData)
}

private func firstNonEmptyLine(_ outputs: String...) -> String {
  for output in outputs {
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if !line.isEmpty {
        return String(line)
      }
    }
  }

  return ""
}
