import Foundation

// Files the Windows installation media needs besides the ISO, verified against pinned digests
class WindowsDownloadCache: PrunableStorage {
  let baseURL: URL

  init() throws {
    baseURL = try Config().tartCacheDir.appendingPathComponent("windows", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
  }

  func prunables() throws -> [Prunable] {
    try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
  }

  func retrieve(_ remoteURL: URL, digest expectedDigest: String, name: String) async throws -> URL {
    let location = baseURL.appendingPathComponent("\(expectedDigest).\(remoteURL.pathExtension)", isDirectory: false)

    if FileManager.default.fileExists(atPath: location.path) {
      defaultLogger.appendNewLine("Using cached \(name)...")
      try location.updateAccessDate()

      return location
    }

    defaultLogger.appendNewLine("Fetching \(name)...")

    let (channel, response) = try await Fetcher.fetch(URLRequest(url: remoteURL), viaFile: true)

    let temporaryLocation = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString + "." + remoteURL.pathExtension)
    FileManager.default.createFile(atPath: temporaryLocation.path, contents: nil)
    let lock = try FileLock(lockURL: temporaryLocation)
    try lock.lock()
    defer { withExtendedLifetime(lock) {} }

    let progress = Progress(totalUnitCount: response.expectedContentLength)
    ProgressObserver(progress).log(defaultLogger)

    let fileHandle = try FileHandle(forWritingTo: temporaryLocation)
    let digest = Digest()

    for try await chunk in channel {
      try fileHandle.write(contentsOf: chunk)
      digest.update(chunk)
      progress.completedUnitCount += Int64(chunk.count)
    }

    try fileHandle.close()

    let actualDigest = digest.finalize()
    if actualDigest != expectedDigest {
      try? FileManager.default.removeItem(at: temporaryLocation)

      throw RuntimeError.Generic("\(remoteURL.lastPathComponent) has digest \(actualDigest), expected \(expectedDigest)")
    }

    return try FileManager.default.replaceItemAt(location, withItemAt: temporaryLocation)!
  }
}
