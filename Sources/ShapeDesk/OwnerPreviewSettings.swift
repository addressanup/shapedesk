#if SHAPEDESK_OWNER_PREVIEW
import Foundation
import Darwin
import ShapeDeskSorting

/// This private file holds a local access token, never the TypeSafe vendor key.
struct OwnerPreviewSettings: Decodable {
    let baseURL: URL
    let credentials: ProCredentials

    static func load() throws -> OwnerPreviewSettings {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShapeDesk/OwnerPreview/client.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProError.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4096 else { throw ProError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let settings = try JSONDecoder().decode(Self.self, from: data)
        guard settings.credentials.licenseKey.count == 64,
              settings.credentials.licenseKey.allSatisfy({ $0.isHexDigit }),
              UUID(uuidString: settings.credentials.instanceID) != nil else { throw ProError.unavailable }
        return settings
    }
}
#endif
