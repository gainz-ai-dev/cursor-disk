import Foundation
#if canImport(OSLog)
import OSLog
#endif

public actor FileIndexActor {
    private(set) var fileMap: [URL: FileInfo] = [:]
    private(set) var isScanning: Bool = false
    private var scanTask: Task<Void, Error>?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cursordisk.app", category: "FileIndexActor")
    private let fileManager = FileManager.default

    private let resourceKeys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .totalFileSizeKey,
        .fileAllocatedSizeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .typeIdentifierKey, .parentDirectoryURLKey, .volumeSupportsVolumeSizesKey
    ]

    private var snapshotURL: URL {
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "CursorDisk.UnknownBundle"
        let snapshotDir = appSupportDir.appendingPathComponent(bundleID).appendingPathComponent("Snapshots")
        
        if !fileManager.fileExists(atPath: snapshotDir.path) {
            do {
                try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("Failed to create snapshot directory at \(snapshotDir.path): \(error.localizedDescription)")
                return fileManager.temporaryDirectory.appendingPathComponent("fileindex.snapshot")
            }
        }
        return snapshotDir.appendingPathComponent("fileindex.snapshot")
    }

    public init() {
        Task {
            await loadSnapshot()
        }
    }

    public func startIndexing(roots: [URL]?) async {
        guard !isScanning else {
            logger.info("Indexing already in progress. Ignoring new request.")
            return
        }
        
        guard let scanRoots = roots, !scanRoots.isEmpty else {
            logger.warning("No roots provided or roots array is empty for indexing. Scan will not start.")
            return
        }

        isScanning = true
        logger.notice("Starting file indexing for roots: \(scanRoots.map { $0.path }.joined(separator: ", "))")
        let osSignpost = OSSignpostID(log: OSLog.pointsOfInterest, object: self)
        os_signpost(.begin, log: OSLog.pointsOfInterest, name: "FileIndexing", signpostID: osSignpost, "Starting scan, root count: %d", scanRoots.count)

        fileMap = [:]
        
        scanTask = Task.detached(priority: .userInitiated) {
            var allScannedInfos: [URL: FileInfo] = [:]
            do {
                var collectedInfosDuringCrawl: [FileInfo] = []
                try await withThrowingTaskGroup(of: [FileInfo].self) { group in
                    for rootURL in scanRoots {
                        if !self.fileManager.isReadableFile(atPath: rootURL.path) {
                            self.logger.warning("No read access to \(rootURL.path), skipping this root.")
                            continue
                        }
                        group.addTask {
                            try Task.checkCancellation()
                            return try await self.crawlDirectoryRecursive(at: rootURL)
                        }
                    }
                    for try await filesInRoot in group {
                        try Task.checkCancellation()
                        collectedInfosDuringCrawl.append(contentsOf: filesInRoot)
                    }
                }
                
                for info in collectedInfosDuringCrawl where !info.isDirectory {
                    allScannedInfos[info.url] = info
                }

                var directoryChildrenMap: [URL: [URL]] = [:]
                var directoryInfoMap: [URL: FileInfo] = [:]

                for info in collectedInfosDuringCrawl {
                    if info.isDirectory {
                        directoryInfoMap[info.url] = info
                    }
                    let parentURL = info.url.deletingLastPathComponent()
                    if parentURL != info.url {
                        directoryChildrenMap[parentURL, default: []].append(info.url)
                    }
                }
                
                var updatedDirectoryInfos: [URL: FileInfo] = directoryInfoMap
                var changedInPass: Bool
                let maxPasses = 10
                var currentPass = 0
                
                repeat {
                    try Task.checkCancellation()
                    changedInPass = false
                    currentPass += 1
                    
                    for (dirURL, var dirInfo) in updatedDirectoryInfos where dirInfo.isDirectory {
                        var newSize: Int64 = 0
                        if let childrenURLs = directoryChildrenMap[dirURL] {
                            for childURL in childrenURLs {
                                if let childInfo = allScannedInfos[childURL] {
                                    newSize += childInfo.size
                                } else if let childDirInfo = updatedDirectoryInfos[childURL], childDirInfo.isDirectory {
                                    newSize += childDirInfo.size
                                }
                            }
                        }
                        if dirInfo.size != newSize {
                            dirInfo = FileInfo(url: dirInfo.url, name: dirInfo.name, isDirectory: true, size: newSize, modificationDate: dirInfo.modificationDate, creationDate: dirInfo.creationDate, uti: dirInfo.uti, parentPath: dirInfo.parentPath)
                            updatedDirectoryInfos[dirURL] = dirInfo
                            allScannedInfos[dirURL] = dirInfo
                            changedInPass = true
                        } else {
                            if allScannedInfos[dirURL] == nil {
                                allScannedInfos[dirURL] = dirInfo
                            }
                        }
                    }
                } while changedInPass && currentPass < maxPasses
                
                if currentPass == maxPasses && changedInPass {
                    self.logger.warning("Directory size aggregation may not have fully converged after \(maxPasses) passes.")
                }

                let finalMap = allScannedInfos
                await self.updateFileMap(with: finalMap)
                await self.finishIndexing()
            } catch is CancellationError {
                await self.handleIndexingCancellation()
            } catch {
                await self.handleIndexingError(error)
            }
        }
    }
    
    /// Updates the main `fileMap` with the newly scanned data.
    /// This method must be called on the actor's execution context.
    private func updateFileMap(with newMap: [URL: FileInfo]) {
        self.fileMap = newMap
    }

    /// Cancels the ongoing indexing process, if any.
    public func cancelIndexing() async {
        guard isScanning, let task = scanTask else {
            logger.info("No indexing in progress to cancel.")
            return
        }
        task.cancel()
    }
    
    private func handleIndexingCancellation() {
        isScanning = false
        scanTask = nil
        logger.notice("File indexing explicitly cancelled.")
        os_signpost(.end, log: OSLog.pointsOfInterest, name: "FileIndexing", "Indexing cancelled by user/system")
    }

    private func finishIndexing() {
        isScanning = false
        scanTask = nil
        logger.notice("File indexing finished. Total items indexed: \(self.fileMap.count)")
        os_signpost(.end, log: OSLog.pointsOfInterest, name: "FileIndexing", "Indexing finished, items: %d", self.fileMap.count)
        persistSnapshot()
    }

    private func handleIndexingError(_ error: Error) {
        isScanning = false
        scanTask = nil
        logger.error("File indexing failed: \(error.localizedDescription)")
        os_signpost(.end, log: OSLog.pointsOfInterest, name: "FileIndexing", "Indexing failed: %@", error.localizedDescription)
    }

    /// Recursively crawls a directory to gather `FileInfo` for all its contents.
    /// Directory sizes are initially set to 0 and aggregated later.
    /// - Parameter directoryURL: The URL of the directory to crawl.
    /// - Returns: An array of `FileInfo` objects found within the directory and its subdirectories.
    private func crawlDirectoryRecursive(at directoryURL: URL) async throws -> [FileInfo] {
        var collectedFileInfos: [FileInfo] = []

        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
            errorHandler: { url, error -> Bool in
                self.logger.warning("Error during enumeration at \(url.path): \(error.localizedDescription). Item will be skipped.")
                return true
            }
        )

        guard let directoryEnumerator = enumerator else {
            logger.error("Failed to create directory enumerator for \(directoryURL.path)")
            return []
        }
        
        do {
            let dirResourceValues = try directoryURL.resourceValues(forKeys: resourceKeys)
            if let dirInfo = createFileInfo(from: directoryURL, resourceValues: dirResourceValues, isKnownDirectory: true) {
                collectedFileInfos.append(dirInfo)
            }
        } catch {
            logger.warning("Could not get resource values for directory \(directoryURL.path): \(error.localizedDescription).")
        }

        while let element = directoryEnumerator.nextObject() {
            guard let fileURL = element as? URL else {
                logger.info("Skipping non-URL element from enumerator.")
                continue
            }
            try Task.checkCancellation()
            
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
                guard let isDirectory = resourceValues.isDirectory else {
                    logger.info("Skipping \(fileURL.path) due to missing isDirectory attribute.")
                    continue
                }

                if let fileInfo = createFileInfo(from: fileURL, resourceValues: resourceValues, isKnownDirectory: isDirectory) {
                    collectedFileInfos.append(fileInfo)
                }

                if isDirectory {
                    // Manually recurse for subdirectories
                    let subdirectoryInfos = try await crawlDirectoryRecursive(at: fileURL)
                    collectedFileInfos.append(contentsOf: subdirectoryInfos)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Could not process \(fileURL.path): \(error.localizedDescription). Skipping item.")
            }
        }
        return collectedFileInfos
    }
    
    /// Helper to create FileInfo from URL and resource values.
    /// Sizes for directories are initialized to 0 here, to be calculated in a separate aggregation step.
    private func createFileInfo(from url: URL, resourceValues: URLResourceValues, isKnownDirectory: Bool) -> FileInfo? {
        guard let name = resourceValues.name,
              let modificationDate = resourceValues.contentModificationDate ?? resourceValues.creationDate,
              let creationDate = resourceValues.creationDate else {
            logger.info("Skipping \(url.path) due to missing essential attributes (name, dates).")
            return nil
        }

        let itemSize: Int64
        if isKnownDirectory {
            itemSize = 0 // Directory sizes will be calculated later
        } else {
            // Prefer totalFileAllocatedSize for more accurate disk usage. Fallback as necessary.
            itemSize = Int64(resourceValues.totalFileAllocatedSize ??
                             resourceValues.fileAllocatedSize ??
                             resourceValues.totalFileSize ??
                             resourceValues.fileSize ?? 0)
        }

        let uti = resourceValues.typeIdentifier
        let parentPath = resourceValues.parentDirectory?.path ?? url.deletingLastPathComponent().path
        if parentPath == url.path && name == "/" { // Special case for root, parent is itself or empty
            // Adjust if necessary, often parent of "/" is "/"
        }

        return FileInfo(
            url: url,
            name: name,
            isDirectory: isKnownDirectory,
            size: itemSize,
            modificationDate: modificationDate,
            creationDate: creationDate,
            uti: uti,
            parentPath: parentPath == url.path ? nil : parentPath // Avoid self-parenting for root like "/"
        )
    }

    // MARK: - Snapshot Persistence

    /// Saves the current `fileMap` to a snapshot on disk.
    private func persistSnapshot() {
        let path = snapshotURL.path
        logger.info("Attempting to persist snapshot to \(path)")
        guard !self.fileMap.isEmpty else {
            logger.info("File map is empty. Skipping snapshot persistence.")
            // Optionally, delete old snapshot if map is now empty after a clear
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try? fileManager.removeItem(at: snapshotURL)
                logger.info("Deleted existing snapshot as current index is empty.")
            }
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // For easier debugging of snapshot file
            let data = try encoder.encode(self.fileMap)
            try data.write(to: snapshotURL, options: .atomic)
            logger.info("Successfully persisted snapshot with \(self.fileMap.count) items to \(path).")
        } catch {
            logger.error("Failed to persist snapshot: \(error.localizedDescription)")
        }
    }

    /// Loads the `fileMap` from a previously saved snapshot on disk.
    /// If the snapshot doesn't exist or is corrupted, the `fileMap` remains empty.
    private func loadSnapshot() {
        let path = snapshotURL.path
        guard fileManager.fileExists(atPath: path) else {
            logger.info("No snapshot found at \(path). Starting with an empty index.")
            return
        }
        logger.info("Attempting to load snapshot from \(path)")
        do {
            let data = try Data(contentsOf: snapshotURL)
            let decoder = JSONDecoder()
            let loadedMap = try decoder.decode([URL: FileInfo].self, from: data)
            self.fileMap = loadedMap
            logger.info("Successfully loaded snapshot with \(self.fileMap.count) items from \(path).")
        } catch {
            logger.error("Failed to load snapshot from \(path): \(error.localizedDescription). Deleting potentially corrupted snapshot.")
            try? fileManager.removeItem(at: snapshotURL)
            fileMap = [:]
        }
    }
    
    // MARK: - Public Accessors

    /// Retrieves all indexed `FileInfo` objects as an array.
    /// - Returns: An array containing all `FileInfo` currently in the index.
    public func getAllFiles() -> [FileInfo] {
        return Array(fileMap.values)
    }

    /// Retrieves a specific `FileInfo` object by its `URL`.
    /// - Parameter url: The `URL` of the file or directory to retrieve.
    /// - Returns: An optional `FileInfo` if found, otherwise `nil`.
    public func getFileInfo(for url: URL) -> FileInfo? {
        return fileMap[url]
    }
    
    /// Returns the total number of items currently in the index.
    /// - Returns: The count of `FileInfo` objects in `fileMap`.
    public func getIndexedFileCount() -> Int {
        return fileMap.count
    }
    
    /// Returns whether the indexer is currently performing a scan.
    /// - Returns: `true` if scanning, `false` otherwise.
    public func getIsScanning() -> Bool {
        return isScanning
    }
    
    /// Clears the entire file index from memory and deletes its snapshot from disk.
    public func clearIndexAndSnapshot() async {
        fileMap = [:]
        let path = snapshotURL.path
        do {
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(at: snapshotURL)
                logger.info("Successfully deleted snapshot at \(path).")
            }
        } catch {
            logger.error("Failed to delete snapshot at \(path): \(error.localizedDescription).")
        }
        logger.info("File index and snapshot cleared.")
    }
}

// MARK: - OSLog Convenience
extension OSLog {
    /// A shared `OSLog` instance for points of interest related to file indexing and app performance.
    static let pointsOfInterest = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.cursordisk.app", category: .pointsOfInterest)
}