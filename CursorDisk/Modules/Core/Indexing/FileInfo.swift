import Foundation

/// Represents metadata for a file or directory in the index.
public struct FileInfo: Identifiable, Hashable, Codable {
    public let id: URL
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64 // Size in bytes. For directories, this is the sum of its contents.
    public let modificationDate: Date
    public let creationDate: Date
    public let uti: String? // Uniform Type Identifier
    public let parentPath: String? // Path of the parent directory, for easier traversal

    // Note: For directories, `size` will be calculated recursively during indexing.
    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Date,
        creationDate: Date,
        uti: String?,
        parentPath: String?
    ) {
        self.id = url
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.uti = uti
        self.parentPath = parentPath
    }
}

// MARK: - Convenience Initializer from URL and Attributes

extension FileInfo {
    /// Creates a `FileInfo` instance from a URL and its attributes.
    /// - Parameters:
    ///   - url: The file URL.
    ///   - attributes: File attributes obtained from `FileManager`.
    ///   - calculatedSize: Optional. For directories, this is the sum of its contents. For files, it's the file's own size.
    init?(url: URL, attributes: [FileAttributeKey: Any], calculatedSize: Int64? = nil) {
        guard let name = url.lastPathComponent as String?,
              let modificationDate = attributes[.modificationDate] as? Date,
              let creationDate = attributes[.creationDate] as? Date
        else {
            // Log error or handle missing essential attributes
            print("Error: Could not initialize FileInfo for URL \(url). Missing essential attributes.")
            return nil
        }

        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        
        // Use calculatedSize if provided (e.g., for directories), otherwise use fileSize.
        let finalSize = calculatedSize ?? fileSize
        
        // Get UTI
        var utiValue: String? = nil
        if let typeIdentifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
            utiValue = typeIdentifier
        }

        self.init(
            url: url,
            name: name,
            isDirectory: isDirectory,
            size: finalSize,
            modificationDate: modificationDate,
            creationDate: creationDate,
            uti: utiValue,
            parentPath: url.deletingLastPathComponent().path
        )
    }
} 