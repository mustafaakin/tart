import XCTest
@testable import tart

final class WindowsDownloadCacheTests: XCTestCase {
  override func setUpWithError() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)

    addTeardownBlock {
      if let previousHome = previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
      try? FileManager.default.removeItem(at: home)
    }
  }

  func testRetrievesCachedFileWithoutDownloading() async throws {
    let cache = try WindowsDownloadCache()
    let cached = cache.baseURL.appendingPathComponent("\(WinFsp.msiDigest).msi")
    XCTAssertTrue(FileManager.default.createFile(atPath: cached.path, contents: nil))

    let retrieved = try await cache.retrieve(WinFsp.msiURL, digest: WinFsp.msiDigest, name: "WinFsp")
    XCTAssertEqual(retrieved.standardizedFileURL, cached.standardizedFileURL)
  }

  func testPrunesEveryDownload() throws {
    let cache = try WindowsDownloadCache()
    for name in ["\(VirtioWin.isoDigest).iso", "\(WinFsp.msiDigest).msi", ".DS_Store"] {
      XCTAssertTrue(FileManager.default.createFile(atPath: cache.baseURL.appendingPathComponent(name).path, contents: nil))
    }

    XCTAssertEqual(try cache.prunables().map(\.url.lastPathComponent).sorted(),
                   ["\(VirtioWin.isoDigest).iso", "\(WinFsp.msiDigest).msi"].sorted())
  }

  func testDriversIncludeDirectorySharing() {
    XCTAssertTrue(VirtioWin.drivers.contains("viofs"))
  }
}
