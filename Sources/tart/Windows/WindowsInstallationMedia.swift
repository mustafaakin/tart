import Foundation

// A disk image that installs Windows without any interaction when attached as USB mass storage.
//
// Its EFI system partition holds a loader that starts the framebuffer driver before Windows Boot Manager.
// The second partition is exFAT, because install.wim doesn't fit FAT32, and holds the ISO's contents, the
// drivers, WinFsp and the setup files, which install Windows and report the result in tart\result.
struct WindowsInstallationMedia {
  let url: URL

  static func validate(_ windowsISO: URL) throws {
    try withMountedISO(windowsISO) { isoRoot in
      try validate(isoRoot: isoRoot, name: windowsISO.lastPathComponent)
    }
  }

  static func validate(isoRoot: URL, name: String) throws {
    let fileExists = { (path: String) in
      FileManager.default.fileExists(atPath: isoRoot.appendingPathComponent(path).path)
    }

    if !fileExists("sources/install.wim") && !fileExists("sources/install.esd") {
      throw RuntimeError.Generic("\(name) is not a Windows installation ISO")
    }

    if !fileExists("efi/boot/bootaa64.efi") {
      throw RuntimeError.Generic("\(name) is not a Windows on ARM installation ISO")
    }
  }

  static func create(at url: URL, windowsISO: URL, virtioWinISO: URL, winFspMSI: URL) throws -> WindowsInstallationMedia {
    // Room for the ISO's contents, the drivers and the EFI system partition
    let isoSize = try windowsISO.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fileHandle = try FileHandle(forWritingTo: url)
    try fileHandle.truncate(atOffset: UInt64(isoSize) + 1024 * 1024 * 1024)
    try fileHandle.close()

    let disk = try Hdiutil.attach(url, mount: false, raw: true)[0].devEntry
    do {
      try populate(disk, windowsISO: windowsISO, virtioWinISO: virtioWinISO, winFspMSI: winFspMSI)
    } catch {
      try? Hdiutil.detach(disk)
      throw error
    }

    // The VM can only use the media once macOS has let go of it
    try Hdiutil.detach(disk)

    return WindowsInstallationMedia(url: url)
  }

  func checkInstallationResult() throws {
    let entities = try Hdiutil.attach(url, readOnly: true, raw: true)
    defer {
      try? Hdiutil.detach(entities[0].devEntry)
    }

    guard let root = entities.compactMap(\.mountPoint).first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
      throw RuntimeError.Generic("failed to mount the Windows installation media to check the installation result")
    }

    let result = try? String(contentsOf: root.appendingPathComponent("tart/result"), encoding: .utf8)
    if result?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" {
      return
    }

    let log = (try? String(contentsOf: root.appendingPathComponent("tart/install.log"), encoding: .isoLatin1)) ?? ""
    let lastLines = log.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")

    throw RuntimeError.Generic("Windows installation failed:\n\(lastLines)")
  }

  private static func populate(_ disk: String, windowsISO: URL, virtioWinISO: URL, winFspMSI: URL) throws {
    try Diskutil.partitionDisk(disk, format: "ExFAT", name: "TART")
    let partitions = try Diskutil.partitions(of: disk)
    guard let efiSystemPartitionInfo = partitions.first(where: { $0.content == "EFI" }),
          let dataPartitionInfo = partitions.first(where: { $0.volumeName == "TART" }) else {
      throw RuntimeError.Generic("failed to partition the Windows installation media")
    }

    // Partitioning mounts the new volume where Finder shows it, so mount both again without that
    try Diskutil.unmountDisk(disk)
    let efiSystemPartition = try Diskutil.mount(efiSystemPartitionInfo.deviceIdentifier)
    let dataPartition = try Diskutil.mount(dataPartitionInfo.deviceIdentifier)

    try withMountedISO(windowsISO) { isoRoot in
      for item in try FileManager.default.contentsOfDirectory(at: isoRoot, includingPropertiesForKeys: nil) {
        try FileManager.default.copyItem(at: item, to: dataPartition.appendingPathComponent(item.lastPathComponent))
      }
    }

    // Windows Boot Manager must only start after the framebuffer driver, which the loader takes care of
    try FileManager.default.moveItem(at: dataPartition.appendingPathComponent("efi/boot/bootaa64.efi"),
                                     to: dataPartition.appendingPathComponent("efi/boot/windows.efi"))

    try VirtioWin.copyDrivers(from: virtioWinISO, to: dataPartition.appendingPathComponent("tart/drivers", isDirectory: true))
    try FileManager.default.copyItem(at: winFspMSI, to: dataPartition.appendingPathComponent("tart/winfsp.msi"))

    try write(WindowsResources.efiSystemPartition, to: efiSystemPartition)
    try write(WindowsResources.dataPartition, to: dataPartition)

    // macOS keeps extended attributes on FAT and exFAT in "._" files, which FileManager doesn't
    // list, and DISM fails on the ones next to the drivers when it looks for *.inf files
    _ = try runTool("dot_clean", ["-m", efiSystemPartition.path])
    _ = try runTool("dot_clean", ["-m", dataPartition.path])
  }

  private static func withMountedISO(_ iso: URL, _ body: (URL) throws -> Void) throws {
    let entities = try Hdiutil.attach(iso, readOnly: true)
    defer {
      try? Hdiutil.detach(entities[0].devEntry)
    }

    guard let root = entities.compactMap(\.mountPoint).first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
      throw RuntimeError.Generic("\(iso.lastPathComponent) has no mountable volume")
    }

    try body(root)
  }

  private static func write(_ files: [String: String], to root: URL) throws {
    for (path, contents) in files {
      let url = root.appendingPathComponent(path)

      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(base64Encoded: contents)!.write(to: url)
    }
  }
}
