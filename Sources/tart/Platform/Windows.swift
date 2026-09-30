import Dynamic
import Virtualization

@available(macOS 13, *)
struct Windows: Platform {
  var machineIdentifier: VZGenericMachineIdentifier

  init(machineIdentifier: VZGenericMachineIdentifier = VZGenericMachineIdentifier()) {
    self.machineIdentifier = machineIdentifier
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let encodedMachineIdentifier = try container.decode(String.self, forKey: .machineIdentifier)
    guard let data = Data(base64Encoded: encodedMachineIdentifier),
          let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
      throw DecodingError.dataCorruptedError(forKey: .machineIdentifier,
                                             in: container,
                                             debugDescription: "failed to initialize VZGenericMachineIdentifier using the provided value")
    }
    self.machineIdentifier = machineIdentifier
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(machineIdentifier.dataRepresentation.base64EncodedString(), forKey: .machineIdentifier)
  }

  // Without PMU and fine-grained trap emulation, Windows Boot Manager
  // never gets past its first instructions
  static func checkHostSupport() throws {
    for selector in ["_setPerformanceMonitoringUnitEmulationEnabled:", "_setFineGrainedTrapsEmulationEnabled:"]
      where !VZGenericPlatformConfiguration.instancesRespond(to: NSSelectorFromString(selector)) {
      throw RuntimeError.VMConfigurationError("Windows VMs are not supported on this version of macOS")
    }
  }

  func os() -> OS {
    .windows
  }

  func bootLoader(nvramURL: URL) throws -> VZBootLoader {
    let result = VZEFIBootLoader()

    result.variableStore = VZEFIVariableStore(url: nvramURL)

    return result
  }

  func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
    let result = VZGenericPlatformConfiguration()

    // Windows ties its hardware identity (and activation) to the machine identifier
    result.machineIdentifier = machineIdentifier

    if #available(macOS 15, *) {
      result.isNestedVirtualizationEnabled = needsNestedVirtualization
    }

    try Self.checkHostSupport()
    Dynamic(result)._setPerformanceMonitoringUnitEmulationEnabled(true)
    Dynamic(result)._setFineGrainedTrapsEmulationEnabled(true)

    return result
  }

  func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
    let result = VZVirtioGraphicsDeviceConfiguration()

    result.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: vmConfig.display.width,
        heightInPixels: vmConfig.display.height
      )
    ]

    return result
  }

  func keyboards(noUSB: Bool) -> [VZKeyboardConfiguration] {
    noUSB ? [] : [VZUSBKeyboardConfiguration()]
  }

  func pointingDevices(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    noUSB ? [] : [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }

  func pointingDevicesSimplified(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    pointingDevices(noUSB: noUSB)
  }
}
