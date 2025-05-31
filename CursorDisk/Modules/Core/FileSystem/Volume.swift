import Foundation

/// Represents a mounted file system volume.
public struct Volume: Identifiable, Hashable {
    public let id: URL
    public let url: URL
    public let name: String
    public let totalCapacity: Int64
    public let freeCapacity: Int64
    public let isRoot: Bool // Indicates if this is the main startup disk

    public init(url: URL, name: String, totalCapacity: Int64, freeCapacity: Int64, isRoot: Bool) {
        self.id = url
        self.url = url
        self.name = name
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.isRoot = isRoot
    }
}

// MARK: - Volume Discovery
public enum VolumeScanner {
    private static let fileManager = FileManager.default

    /// Scans for all mounted volumes that are not hidden and are accessible.
    /// - Returns: An array of `Volume` objects.
    public static func discoverVolumes() -> [Volume] {
        var discoveredVolumes: [Volume] = []
        let volumeKeys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey]
        
        guard let mountedVolumeURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: volumeKeys, options: [.skipHiddenVolumes]) else {
            // Consider logging this error appropriately in a real app
            print("Error: Could not retrieve mounted volume URLs.")
            return []
        }

        for volumeURL in mountedVolumeURLs {
            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: Set(volumeKeys))
                
                guard let name = resourceValues.volumeName,
                      let totalCapacity = resourceValues.volumeTotalCapacity,
                      let freeCapacity = resourceValues.volumeAvailableCapacity
                else {
                    // Log issue with retrieving necessary resource values for this volume
                    print("Warning: Missing required volume attributes for \\(volumeURL.path). Skipping.")
                    continue
                }
                
                // Check if it's the root file system (startup disk)
                // .volumeIsRootFileSystemKey can sometimes be nil or false for the actual root if queried weirdly.
                // A more robust check is often comparing the path to "/".
                let isRoot = volumeURL.path == "/" || (resourceValues.volumeIsRootFileSystem ?? false)

                let volume = Volume(
                    url: volumeURL,
                    name: name.isEmpty ? "Untitled Volume" : name, // Provide a default name if empty
                    totalCapacity: Int64(totalCapacity),
                    freeCapacity: Int64(freeCapacity),
                    isRoot: isRoot
                )
                discoveredVolumes.append(volume)
            } catch {
                // Log error retrieving resource values for a specific volume
                print("Error: Could not get resource values for volume at \\(volumeURL.path): \\(error.localizedDescription). Skipping.")
            }
        }
        return discoveredVolumes
    }
} 