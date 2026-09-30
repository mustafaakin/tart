import XCTest
@testable import tart

final class WindowsInstallationMediaTests: XCTestCase {
  func testAcceptsWindowsOnARMISO() throws {
    try WindowsInstallationMedia.validate(isoRoot: try isoRoot(with: ["sources/install.wim", "efi/boot/bootaa64.efi"]), name: "arm64.iso")
    try WindowsInstallationMedia.validate(isoRoot: try isoRoot(with: ["sources/install.esd", "efi/boot/bootaa64.efi"]), name: "arm64.iso")
  }

  func testRejectsOtherISOs() throws {
    let x64 = try isoRoot(with: ["sources/install.wim", "efi/boot/bootx64.efi"])
    XCTAssertThrowsError(try WindowsInstallationMedia.validate(isoRoot: x64, name: "x64.iso")) { error in
      XCTAssertEqual("\(error)", "x64.iso is not a Windows on ARM installation ISO")
    }

    let linux = try isoRoot(with: ["casper/vmlinuz", "EFI/boot/bootaa64.efi"])
    XCTAssertThrowsError(try WindowsInstallationMedia.validate(isoRoot: linux, name: "ubuntu.iso")) { error in
      XCTAssertEqual("\(error)", "ubuntu.iso is not a Windows installation ISO")
    }
  }

  func testEmbeddedResources() throws {
    XCTAssertEqual(WindowsResources.efiSystemPartition.keys.sorted(), ["EFI/BOOT/BOOTAA64.EFI", "EFI/tart/framebuffer.efi"])
    XCTAssertEqual(WindowsResources.dataPartition.keys.sorted(),
                   ["autounattend.xml", "tart/SetupComplete.cmd", "tart/extend-c.ps1", "tart/framebuffer.efi", "tart/install.cmd"])

    for (path, contents) in Array(WindowsResources.efiSystemPartition) + Array(WindowsResources.dataPartition) {
      let data = try XCTUnwrap(Data(base64Encoded: contents), path)

      if path.hasSuffix(".efi") || path.hasSuffix(".EFI") {
        XCTAssertEqual(data.prefix(2), Data("MZ".utf8), path)
      }
      if path.hasSuffix(".cmd") {
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\r\n"), path)
      }
    }
  }

  private func isoRoot(with files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }

    for file in files {
      let url = root.appendingPathComponent(file)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    return root
  }
}
