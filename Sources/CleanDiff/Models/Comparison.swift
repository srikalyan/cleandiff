import Foundation

enum ComparisonType {
    case file
    case directory
    case threeWay
}

struct Comparison: Identifiable {
    let id = UUID()
    let leftURL: URL
    let rightURL: URL
    let baseURL: URL?
    let mergedURL: URL?  // Output file for git mergetool
    let createdAt = Date()

    init(leftURL: URL, rightURL: URL, baseURL: URL? = nil, mergedURL: URL? = nil) {
        self.leftURL = leftURL
        self.rightURL = rightURL
        self.baseURL = baseURL
        self.mergedURL = mergedURL
    }

    var type: ComparisonType {
        if baseURL != nil {
            return .threeWay
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: leftURL.path, isDirectory: &isDir), isDir.boolValue {
            return .directory
        }
        return .file
    }

    var title: String {
        let leftName = leftURL.lastPathComponent
        let rightName = rightURL.lastPathComponent
        if leftName == rightName {
            return leftName
        }
        return "\(leftName) ↔ \(rightName)"
    }

    var icon: String {
        switch type {
        case .file: return "doc.text"
        case .directory: return "folder"
        case .threeWay: return "arrow.triangle.merge"
        }
    }
}
