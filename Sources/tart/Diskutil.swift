import Foundation

struct ImageInfo: Codable {
  let sizeInfo: SizeInfo?
  let size: UInt64?

  enum CodingKeys: String, CodingKey {
    case sizeInfo = "Size Info"
    case size = "Size"
  }

  func totalBytes() throws -> Int {
    if let totalBytes = self.sizeInfo?.totalBytes {
      return Int(totalBytes)
    }

    if let size = self.size {
      return Int(size)
    }

    throw RuntimeError.Generic("Could not find size information in disk image info")
  }
}

struct SizeInfo: Codable {
  let totalBytes: UInt64?

  enum CodingKeys: String, CodingKey {
    case totalBytes = "Total Bytes"
  }
}

struct VolumeInfo: Codable {
  let mountPoint: String?

  enum CodingKeys: String, CodingKey {
    case mountPoint = "MountPoint"
  }
}

struct PartitionInfo: Codable {
  let deviceIdentifier: String
  let content: String?
  let volumeName: String?

  enum CodingKeys: String, CodingKey {
    case deviceIdentifier = "DeviceIdentifier"
    case content = "Content"
    case volumeName = "VolumeName"
  }
}

private struct DiskList: Codable {
  struct Disk: Codable {
    let partitions: [PartitionInfo]?

    enum CodingKeys: String, CodingKey {
      case partitions = "Partitions"
    }
  }

  let allDisksAndPartitions: [Disk]

  enum CodingKeys: String, CodingKey {
    case allDisksAndPartitions = "AllDisksAndPartitions"
  }
}

struct Diskutil {
  static func imageCreate(diskURL: URL, sizeGB: UInt16) throws {
    do {
      _ = try run([
        "image", "create", "blank",
        "--format", "ASIF",
        "--size", "\(sizeGB)G",
        "--volumeName", "Tart",
        diskURL.path
      ])
    } catch {
      throw RuntimeError.FailedToCreateDisk("Failed to create ASIF disk image: \(error)")
    }
  }

  static func imageInfo(_ diskURL: URL) throws -> ImageInfo {
    do {
      let (stdoutData, _) = try run([
        "image", "info", "--plist",
        diskURL.path
      ])

      do {
        return try PropertyListDecoder().decode(ImageInfo.self, from: stdoutData)
      } catch {
        throw RuntimeError.Generic("Failed to parse \"diskutil image info --plist\" output: \(error)")
      }
    }
  }

  // On disks larger than a few gigabytes, this also creates an EFI system partition in front
  static func partitionDisk(_ device: String, format: String, name: String) throws {
    _ = try run(["partitionDisk", device, "1", "GPT", format, name, "R"])
  }

  static func partitions(of device: String) throws -> [PartitionInfo] {
    let (stdoutData, _) = try run(["list", "-plist", device])

    return try PropertyListDecoder().decode(DiskList.self, from: stdoutData).allDisksAndPartitions.first?.partitions ?? []
  }

  static func unmountDisk(_ device: String) throws {
    _ = try run(["unmountDisk", device])
  }

  // Mounts a volume without showing it in Finder
  static func mount(_ device: String) throws -> URL {
    _ = try run(["mount", "nobrowse", device])

    let (stdoutData, _) = try run(["info", "-plist", device])
    let info = try PropertyListDecoder().decode(VolumeInfo.self, from: stdoutData)
    guard let mountPoint = info.mountPoint, !mountPoint.isEmpty else {
      throw RuntimeError.Generic("\(device) has no mount point after mounting it")
    }

    return URL(fileURLWithPath: mountPoint, isDirectory: true)
  }

  private static func run(_ arguments: [String]) throws -> (Data, Data) {
    try runTool("diskutil", arguments)
  }
}
