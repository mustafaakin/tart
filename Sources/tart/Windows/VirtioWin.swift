import Foundation

class VirtioWinCache: PrunableStorage {
  let baseURL: URL

  init() throws {
    baseURL = try Config().tartCacheDir.appendingPathComponent("virtio-win", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
  }

  func locationFor(fileName: String) -> URL {
    baseURL.appendingPathComponent(fileName, isDirectory: false)
  }

  func prunables() throws -> [Prunable] {
    try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".iso") }
  }
}

// Windows drivers for the virtual hardware, from the Fedora virtio-win project
enum VirtioWin {
  static let isoURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
  static let isoDigest = "sha256:303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"

  // Storage, display, network and entropy
  static let drivers = ["viostor", "viogpudo", "NetKVM", "viorng"]

  static func retrieveISO() async throws -> URL {
    let location = try VirtioWinCache().locationFor(fileName: "\(isoDigest).iso")

    if FileManager.default.fileExists(atPath: location.path) {
      defaultLogger.appendNewLine("Using cached virtio-win drivers...")
      try location.updateAccessDate()

      return location
    }

    defaultLogger.appendNewLine("Fetching virtio-win drivers...")

    let (channel, response) = try await Fetcher.fetch(URLRequest(url: isoURL), viaFile: true)

    let temporaryLocation = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString + ".iso")
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
    if actualDigest != isoDigest {
      try? FileManager.default.removeItem(at: temporaryLocation)

      throw RuntimeError.Generic("\(isoURL.lastPathComponent) has digest \(actualDigest), expected \(isoDigest)")
    }

    return try FileManager.default.replaceItemAt(location, withItemAt: temporaryLocation)!
  }

  // Copies the Windows 11 ARM64 build of each driver into a lowercase directory named after it,
  // leaving out debug symbols but keeping the helper binaries some of the INF files reference
  static func copyDrivers(from isoURL: URL, to directory: URL) throws {
    let entities = try Hdiutil.attach(isoURL, readOnly: true)
    defer {
      try? Hdiutil.detach(entities[0].devEntry)
    }

    guard let root = entities.compactMap(\.mountPoint).first else {
      throw RuntimeError.Generic("\(isoURL.lastPathComponent) has no mountable volume")
    }

    for driver in drivers {
      let source = URL(fileURLWithPath: root).appendingPathComponent("\(driver)/w11/ARM64", isDirectory: true)
      let destination = directory.appendingPathComponent(driver.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

      for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where file.pathExtension.lowercased() != "pdb" {
        try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
      }
    }
  }
}
