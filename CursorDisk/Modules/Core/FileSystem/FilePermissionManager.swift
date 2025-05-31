import Foundation
#if canImport(AppKit)
import AppKit // Required for NSWorkspace
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers // For UTType if needed for specific checks
#endif

/// Manages and checks for Full Disk Access (FDA) permission.
public enum FilePermissionManager {

    private static let fdaRequestedKey = "com.cursordisk.fdaRequestedPreviously"

    /// Represents the current Full Disk Access authorization status.
    public enum FDAStatus: Equatable {
        /// FDA has been granted.
        case granted
        /// FDA has not been granted.
        case denied
        /// FDA status is undetermined (e.g., before first check or request on macOS 13+).
        case undetermined
        /// Could not check status due to an error.
        case error(String)
    }

    /// Asynchronously checks the current Full Disk Access status.
    ///
    /// On macOS 13 and later, there isn't a direct API to query FDA status without attempting
    /// to access a protected resource. This method attempts to list contents of a protected directory
    /// (`~/Library/Mail`) as a proxy for checking FDA. This is a common heuristic.
    ///
    /// - Returns: A `FDAStatus` indicating the current permission state.
    public static func checkFDAStatus() async -> FDAStatus {
        // For macOS 13+, the most reliable check (without a dedicated entitlement/helper tool)
        // is to try accessing a known protected resource.
        // ~/Library/Mail is a common choice. Access to ~/Documents or ~/Downloads might be granted
        // via TCC even without full FDA for some apps, making them less reliable indicators for *full* disk access.
        let protectedURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")

        do {
            _ = try FileManager.default.contentsOfDirectory(at: protectedURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            // If the above line doesn't throw an error, we likely have FDA.
            return .granted
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                // Explicitly no permission. Check if we've asked before.
                if UserDefaults.standard.bool(forKey: fdaRequestedKey) {
                    return .denied // We asked, and it's still denied.
                } else {
                    return .undetermined // Haven't asked, or state is unclear prior to first true attempt.
                }
            } else {
                // Other errors (e.g., directory doesn't exist, though Mail usually does).
                // This could be an issue with the check itself, or an unexpected state.
                // For simplicity, we'll treat other errors as undetermined or a specific error.
                // In a production app, you might log this error for diagnostics.
                return .error("Failed to check FDA status: \(error.localizedDescription)")
            }
        }
    }

    /// Requests Full Disk Access by guiding the user to System Settings.
    ///
    /// This method opens the Full Disk Access section within System Settings (Preferences).
    /// The user must manually grant permission to the application.
    /// It also sets a flag indicating that an FDA request has been made.
    #if canImport(AppKit)
    public static func requestFullDiskAccess() {
        // URL for macOS 13 (Ventura) and later.
        // For older macOS versions, the preference pane path might differ slightly,
        // but this format is generally robust.
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_FullDiskAccess"

        guard let url = URL(string: urlString) else {
            // Log error: Could not create URL for Full Disk Access settings.
            // This should ideally not happen with a hardcoded, valid URL string.
            print("Critical Error: Could not construct URL for Full Disk Access system settings.")
            return
        }
        NSWorkspace.shared.open(url)
        UserDefaults.standard.set(true, forKey: fdaRequestedKey)
    }
    #endif
    
    /// Resets the flag indicating that an FDA request has been made.
    /// Useful for testing or if the app wants to re-trigger certain UI based on this flag.
    public static func resetFDARequestedFlag() {
        UserDefaults.standard.removeObject(forKey: fdaRequestedKey)
    }
} 