import Foundation

// Windows drivers for the virtual hardware, from the Fedora virtio-win project
enum VirtioWin {
  static let isoURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
  static let isoDigest = "sha256:303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"

  // Storage, display, network, entropy and directory sharing
  static let drivers = ["viostor", "viogpudo", "NetKVM", "viorng", "viofs"]

  static func retrieveISO() async throws -> URL {
    try await WindowsDownloadCache().retrieve(isoURL, digest: isoDigest, name: "virtio-win drivers")
  }

  // Copies the Windows 11 ARM64 build of each driver into a lowercase directory named after it,
  // leaving out debug symbols but keeping the helper binaries, like the virtio-fs service
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
