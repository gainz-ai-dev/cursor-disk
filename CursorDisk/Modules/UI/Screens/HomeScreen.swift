import SwiftUI

@MainActor
class HomeViewModel: ObservableObject {
    @Published var fdaStatus: FilePermissionManager.FDAStatus = .undetermined {
        didSet {
            shouldShowFDAGuidanceSheet = (fdaStatus != .granted)
        }
    }
    @Published var indexedFileCount: Int = 0
    @Published var isScanning: Bool = false
    @Published var volumes: [Volume] = []
    @Published var shouldShowFDAGuidanceSheet: Bool = false // New state for sheet
    
    private let fileIndexActor = FileIndexActor()

    init() {
        Task {
            await checkFDAPermissions()
            // Initial load of volumes. Could be refreshed if needed.
            self.volumes = VolumeScanner.discoverVolumes()
            // Load initial count from snapshot if available
            self.indexedFileCount = await fileIndexActor.getIndexedFileCount()
        }
    }

    func checkFDAPermissions() async {
        let newStatus = await FilePermissionManager.checkFDAStatus()
        if newStatus != self.fdaStatus { // Only update if status has changed to avoid re-triggering UI too often
            self.fdaStatus = newStatus
        }
        // The didSet on fdaStatus will handle shouldShowFDAGuidanceSheet
    }

    func requestFDAPermissions() {
        FilePermissionManager.requestFullDiskAccess()
        // User will be taken to Settings. App will likely go to background.
        // Re-check will happen when scene becomes active.
    }

    func startFullScan() async {
        guard fdaStatus == .granted else {
            print("Error: Full Disk Access is required to start a scan.")
            shouldShowFDAGuidanceSheet = true // Ensure guidance is shown if scan is attempted without permission
            return
        }
        isScanning = true
        shouldShowFDAGuidanceSheet = false // Hide sheet if scan starts
        
        let rootsToScan = volumes.map { $0.url }
        if rootsToScan.isEmpty {
            print("Warning: No volumes discovered to scan. Defaulting to root '/' if FDA granted.")
            await fileIndexActor.startIndexing(roots: [URL(fileURLWithPath: "/")])
        } else {
            await fileIndexActor.startIndexing(roots: rootsToScan)
        }
        
        while await fileIndexActor.getIsScanning() {
            do {
                try await Task.sleep(for: .seconds(0.5)) 
            } catch {
                // Handle cancellation of sleep task if needed
                break
            }
            self.indexedFileCount = await fileIndexActor.getIndexedFileCount()
        }
        self.indexedFileCount = await fileIndexActor.getIndexedFileCount()
        isScanning = false
    }
    
    func cancelScan() async {
        await fileIndexActor.cancelIndexing()
        isScanning = false
        self.indexedFileCount = await fileIndexActor.getIndexedFileCount()
    }
    
    func clearIndex() async {
        await fileIndexActor.clearIndexAndSnapshot()
        self.indexedFileCount = 0
    }
}

struct HomeScreen: View {
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("CursorDisk")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Material.ultraThinMaterial) // Subtle background for header

            Divider()

            if viewModel.fdaStatus == .granted {
                mainContentView
            } else {
                VStack {
                    Spacer()
                    Text("Checking permissions...")
                    ProgressView()
                    Spacer()
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 1000, minHeight: 500, idealHeight: 700)
        .background(colorScheme == .dark ? Color.black.opacity(0.3) : Color.gray.opacity(0.1))
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    await viewModel.checkFDAPermissions()
                }
            }
        }
        .sheet(isPresented: $viewModel.shouldShowFDAGuidanceSheet) {
            FDAGuidanceView(viewModel: viewModel)
        }
        .onAppear {
             // Initial check when view appears, after init has run
            Task {
                await viewModel.checkFDAPermissions()
            }
        }
    }

    private var mainContentView: some View {
        VStack(spacing: 15) {
            // Scan Controls and Info
            VStack(alignment: .leading, spacing: 12) {
                VolumeListView(volumes: viewModel.volumes)

                HStack {
                    Spacer()
                    Text("Indexed: \(viewModel.indexedFileCount) items")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Material.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                

                if viewModel.isScanning {
                    HStack {
                        ProgressView("Scanning... ")
                            .progressViewStyle(.linear)
                        Spacer()
                        Button {
                            Task { await viewModel.cancelScan() }
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                    }
                    .padding(.horizontal, 20)
                } else {
                    HStack(spacing: 20) {
                        Button {
                            Task { await viewModel.startFullScan() }
                        } label: {
                            Label("Start Full Scan", systemImage: "play.circle.fill")
                                .padding(.horizontal)
                        }
                        .controlSize(.large)
                        .tint(.accentColor)
                        
                        Button {
                            Task { await viewModel.clearIndex() }
                        } label: {
                            Label("Clear Index", systemImage: "trash.circle.fill")
                        }
                        .controlSize(.large)
                        .tint(.orange)
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Chart Area Placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Material.ultraThickMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                
                ChartView(progress: rootUsage)
                    .padding(10)
            }
            .padding(20)
            
            Spacer() // Pushes content up
        }
    }

    private var rootUsage: Double {
        guard let root = viewModel.volumes.first(where: { $0.isRoot }) else {
            return 0
        }
        return 1 - Double(root.freeCapacity) / Double(root.totalCapacity)
    }
}

struct FDAGuidanceView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Full Disk Access Required")
                .font(.title2.bold())

            Text(
                "CursorDisk needs Full Disk Access to scan your files and help you manage your storage. " + 
                "Please grant access in System Settings."
            )
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 10) {
                 Text("1. Click \"Open System Settings\".")
                 Text("2. Find CursorDisk in the list.")
                 Text("3. Turn the switch ON to grant access.")
                 Text("4. Return to CursorDisk (it may restart or require you to click \"Re-check\").")
            }
            .font(.callout)
            .padding()
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Button {
                viewModel.requestFDAPermissions()
            } label: {
                Label("Open System Settings", systemImage: "gearshape.arrow.triangle.2.circlepath")
                    .padding(.horizontal)
            }
            .controlSize(.large)
            .padding(.top)
            
            Button("Re-check Permissions & Dismiss") {
                Task {
                    await viewModel.checkFDAPermissions()
                    if viewModel.fdaStatus == .granted {
                        dismiss()
                    }
                }
            }
             .controlSize(.regular)
        }
        .padding(30)
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 550, minHeight: 400, idealHeight: 450, maxHeight: .infinity, alignment: .center)
    }
}

#Preview("Home Screen") {
    HomeScreen()
}

#Preview("FDA Guidance Sheet") {
    FDAGuidanceView(viewModel: HomeViewModel())
} 