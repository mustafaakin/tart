import Foundation

struct Hdiutil {
  struct Entity: Decodable {
    let devEntry: String
    let mountPoint: String?

    enum CodingKeys: String, CodingKey {
      case devEntry = "dev-entry"
      case mountPoint = "mount-point"
    }
  }

  private struct AttachResult: Decodable {
    let systemEntities: [Entity]

    enum CodingKeys: String, CodingKey {
      case systemEntities = "system-entities"
    }
  }

  // Returns the whole disk first, followed by its partitions
  static func attach(_ imageURL: URL, readOnly: Bool = false, mount: Bool = true, raw: Bool = false) throws -> [Entity] {
    var arguments = ["attach", "-plist", "-nobrowse"]
    if readOnly {
      arguments.append("-readonly")
    }
    if !mount {
      arguments.append("-nomount")
    }
    if raw {
      arguments += ["-imagekey", "diskimage-class=CRawDiskImage"]
    }
    arguments.append(imageURL.path)

    let (stdoutData, _) = try runTool("hdiutil", arguments)

    // "/dev/disk7" sorts before its "/dev/disk7s1" partition, whatever order hdiutil lists them in
    let entities = try PropertyListDecoder().decode(AttachResult.self, from: stdoutData).systemEntities
      .sorted { $0.devEntry.count < $1.devEntry.count }
    if entities.isEmpty {
      throw RuntimeError.Generic("\"hdiutil attach\" returned no devices for \(imageURL.path)")
    }

    return entities
  }

  static func detach(_ device: String) throws {
    _ = try runTool("hdiutil", ["detach", "-force", device])
  }
}
