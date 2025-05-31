import SwiftUI

struct VolumeListView: View {
    var volumes: [Volume]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(volumes) { volume in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.headline)
                        Text("\(formatByte(volume.freeCapacity)) free of \(formatByte(volume.totalCapacity))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    ProgressView(value: usedPercent(volume))
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                    Text(percentText(volume))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func usedPercent(_ volume: Volume) -> Double {
        guard volume.totalCapacity > 0 else { return 0 }
        return 1 - Double(volume.freeCapacity) / Double(volume.totalCapacity)
    }

    private func percentText(_ volume: Volume) -> String {
        String(format: "%.0f%%", usedPercent(volume) * 100)
    }

    private func formatByte(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

#Preview {
    VolumeListView(volumes: [
        Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", totalCapacity: 100_000_000_000, freeCapacity: 40_000_000_000, isRoot: true),
        Volume(url: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup", totalCapacity: 200_000_000_000, freeCapacity: 120_000_000_000, isRoot: false)
    ])
        .padding()
        .frame(width: 400)
}
