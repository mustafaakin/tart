import Foundation
import Virtualization

// Installs Windows from an ISO in two boots: from the installation media, which applies the image and
// powers off, and then from the installed system, which completes setup and powers off again.
struct WindowsInstaller {
  let isoURL: URL

  func install(vmDir: VMDirectory, diskSizeGB: UInt16, diskFormat: DiskImageFormat) async throws {
    try Windows.checkHostSupport()
    try WindowsInstallationMedia.validate(isoURL)

    let virtioWinISO = try await VirtioWin.retrieveISO()

    defaultLogger.appendNewLine("Creating Windows installation media...")

    // Lock the directory rather than the image, which hdiutil opens exclusively
    let mediaDir = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: mediaDir)
    }
    let mediaLock = try FileLock(lockURL: mediaDir)
    try mediaLock.lock()
    defer { withExtendedLifetime(mediaLock) {} }

    let media = try WindowsInstallationMedia.create(at: mediaDir.appendingPathComponent("windows.img"),
                                                    windowsISO: isoURL, virtioWinISO: virtioWinISO)

    _ = try VZEFIVariableStore(creatingVariableStoreAt: vmDir.nvramURL)
    try vmDir.resizeDisk(diskSizeGB, format: diskFormat)
    let config = VMConfig(platform: Windows(), cpuCountMin: 4, memorySizeMin: 4096 * 1024 * 1024, diskFormat: diskFormat)
    try config.save(toURL: vmDir.configURL)

    defaultLogger.appendNewLine("Installing Windows...")

    let mediaDevice = VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: media.url, readOnly: false))
    try await runUntilGuestStops(try VM(vmDir: vmDir, additionalStorageDevices: [mediaDevice], audio: false, clipboard: false),
                                 timeout: .seconds(30 * 60))
    try media.checkInstallationResult()

    // The media is as big as the ISO, so don't keep it around while Windows sets itself up
    try FileManager.default.removeItem(at: media.url)

    defaultLogger.appendNewLine("Setting up Windows, this takes a while...")

    try await runUntilGuestStops(try VM(vmDir: vmDir, audio: false, clipboard: false), timeout: .seconds(90 * 60))
  }

  private func runUntilGuestStops(_ vm: VM, timeout: Duration) async throws {
    try await vm.start(recovery: false, resume: false)

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await vm.run()
        }
        group.addTask {
          try await Task.sleep(for: timeout)

          throw RuntimeError.Generic("Windows installation didn't finish in \(timeout.components.seconds / 60) minutes")
        }

        try await group.next()
        group.cancelAll()
      }
    } catch is CancellationError {
      // Reported below, whichever of the tasks finished first
    }

    // On Ctrl+C, vm.run() stops the VM before returning
    if Task.isCancelled {
      throw RuntimeError.Generic("Windows installation was cancelled")
    }

    if await MainActor.run(body: { vm.virtualMachine.state == .error }) {
      throw RuntimeError.Generic("Windows installation failed: the virtual machine stopped with an error")
    }
  }
}
