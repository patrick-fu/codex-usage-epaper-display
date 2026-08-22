import Foundation

enum RepoRoot {
    static func url(filePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: filePath)
        while url.lastPathComponent != "Tests" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        url.deleteLastPathComponent()
        return url
    }
}
