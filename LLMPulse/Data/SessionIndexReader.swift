import Foundation

struct SessionIndexReader: Sendable {
    func readTitles(from url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DataAdapterError.missingFile(url)
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var titles: [String: String] = [:]

        data.enumerateJSONLines { object in
            guard
                let threadId = JSONValueSupport.string(object["id"]),
                let title = JSONValueSupport.string(object["thread_name"])
            else {
                return
            }
            titles[threadId] = title
        }

        return titles
    }
}

extension Data {
    func enumerateJSONLines(_ body: ([String: Any]) -> Void) {
        var lineStart = startIndex

        while lineStart < endIndex {
            let lineEnd = self[lineStart...].firstIndex(of: 0x0A) ?? endIndex
            if lineEnd > lineStart {
                let line = Data(self[lineStart..<lineEnd])
                if let object = JSONValueSupport.object(from: line) {
                    body(object)
                }
            }

            guard lineEnd < endIndex else { break }
            lineStart = index(after: lineEnd)
        }
    }
}
