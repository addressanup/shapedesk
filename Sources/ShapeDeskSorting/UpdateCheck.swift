import Foundation

public struct AppRelease: Decodable, Equatable, Sendable {
    public let version: String
    public let url: URL
    private enum CodingKeys: String, CodingKey { case version = "tag_name", url = "html_url" }
}

/// Looks up the latest published GitHub release, the same one the website's
/// download button serves.
public enum UpdateCheck {
    static let latestRelease = URL(string: "https://api.github.com/repos/addressanup/shapedesk/releases/latest")!

    public static func latest() async throws -> AppRelease {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        // Only ever offer to open the project's own release pages.
        guard release.url.scheme == "https", release.url.host == "github.com",
              release.url.path.hasPrefix("/addressanup/shapedesk/") else { throw URLError(.badServerResponse) }
        return release
    }

    /// Compares dotted versions numerically; a leading "v" and suffixes such as "-beta" are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func numbers(_ version: String) -> [Int] {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        var parts: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard let number = Int(digits) else { break }
            parts.append(number)
            if digits.count != part.count { break }
        }
        return parts
    }
}
