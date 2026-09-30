import Dynamic
import Virtualization
import XCTest
@testable import tart

final class WindowsPlatformTests: XCTestCase {
  func testEmulationIsEnabled() throws {
    let platform = try Windows().platform(nvramURL: URL(fileURLWithPath: "/dev/null"), needsNestedVirtualization: false)

    XCTAssertEqual(Dynamic(platform)._performanceMonitoringUnitEmulationEnabled.asBool, true)
    XCTAssertEqual(Dynamic(platform)._fineGrainTrapsEmulationEnabled.asBool, true)
  }

  func testMachineIdentifierIsPersisted() throws {
    let windows = Windows()
    let config = VMConfig(platform: windows, cpuCountMin: 4, memorySizeMin: 4 * 1024 * 1024 * 1024)

    let decoded = try VMConfig(fromJSON: config.toJSON())

    XCTAssertEqual(decoded.os, .windows)
    XCTAssertEqual((decoded.platform as? Windows)?.machineIdentifier.dataRepresentation,
                   windows.machineIdentifier.dataRepresentation)
  }

  func testNewMACAddressComesWithNewMachineIdentifier() throws {
    let source = try temporaryVMDirectory()
    try VMConfig(platform: Windows(), cpuCountMin: 4, memorySizeMin: 4 * 1024 * 1024 * 1024).save(toURL: source.configURL)
    FileManager.default.createFile(atPath: source.nvramURL.path, contents: Data())
    FileManager.default.createFile(atPath: source.diskURL.path, contents: Data())

    let clone = try temporaryVMDirectory()
    try source.clone(to: clone, generateMAC: false)
    XCTAssertEqual(try machineIdentifier(clone), try machineIdentifier(source))

    try clone.regenerateMACAddress()
    XCTAssertNotEqual(try machineIdentifier(clone), try machineIdentifier(source))
  }

  private func machineIdentifier(_ vmDir: VMDirectory) throws -> Data? {
    (try VMConfig(fromURL: vmDir.configURL).platform as? Windows)?.machineIdentifier.dataRepresentation
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return VMDirectory(baseURL: url)
  }
}
