import SwiftUI

// MARK: - Mock Data

struct MockDrive: Identifiable {
    let id: Int
    let name: String
    let totalBytes: Int64
    let usedBytes: Int64
    let fileCount: Int
    let lastScan: String?
    let isMounted: Bool
    let mediaType: String  // "SSD" or "HDD"

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

let mockDrives: [MockDrive] = [
    MockDrive(id: 1, name: "A SSD", totalBytes: 2_000_000_000_000, usedBytes: 1_450_000_000_000, fileCount: 42_381, lastScan: "2h ago", isMounted: true, mediaType: "SSD"),
    MockDrive(id: 2, name: "B SSD", totalBytes: 4_000_000_000_000, usedBytes: 2_890_000_000_000, fileCount: 128_744, lastScan: "1d ago", isMounted: true, mediaType: "SSD"),
    MockDrive(id: 3, name: "C SSD", totalBytes: 4_000_000_000_000, usedBytes: 3_100_000_000_000, fileCount: 95_200, lastScan: "3d ago", isMounted: false, mediaType: "SSD"),
    MockDrive(id: 4, name: "1 HDD", totalBytes: 8_000_000_000_000, usedBytes: 6_200_000_000_000, fileCount: 312_500, lastScan: "1w ago", isMounted: false, mediaType: "HDD"),
    MockDrive(id: 5, name: "LX 1TB", totalBytes: 1_000_000_000_000, usedBytes: 780_000_000_000, fileCount: 18_220, lastScan: "2d ago", isMounted: true, mediaType: "SSD"),
]

// MARK: - Drive Dashboard

struct DriveDashboard: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero summary
                HeroCard()

                // Card grid
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ], spacing: 16) {
                    ConnectedDrivesCard()
                    StorageOverviewCard()
                    IntegrityCard()
                    RecentActivityCard()
                }

                // Drive list
                DriveListCard()
            }
            .padding(20)
        }
    }
}

// MARK: - Hero Card

struct HeroCard: View {
    private var mountedCount: Int { mockDrives.filter(\.isMounted).count }
    private var totalCount: Int { mockDrives.count }
    private var totalStorage: Int64 { mockDrives.reduce(0) { $0 + $1.totalBytes } }
    private var totalFiles: Int { mockDrives.reduce(0) { $0 + $1.fileCount } }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Drive Catalog")
                    .font(.title.bold())

                Text("\(mountedCount) of \(totalCount) drives connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {
                    StatPill(value: formatBytes(totalStorage), label: "Total Storage")
                    StatPill(value: formatCount(totalFiles), label: "Files Cataloged")
                    StatPill(value: "98.2%", label: "Hashed")
                }
                .padding(.top, 4)
            }

            Spacer()

            // Mini drive status dots
            HStack(spacing: 8) {
                ForEach(mockDrives) { drive in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(drive.isMounted ? .green : .gray.opacity(0.4))
                            .frame(width: 10, height: 10)
                        Text(drive.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct StatPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connected Drives Card

struct ConnectedDrivesCard: View {
    private var mounted: [MockDrive] { mockDrives.filter(\.isMounted) }

    var body: some View {
        DashboardCard(title: "Connected Drives", icon: "externaldrive.fill.badge.checkmark", color: .green) {
            VStack(spacing: 8) {
                ForEach(mounted) { drive in
                    HStack(spacing: 10) {
                        Image(systemName: drive.mediaType == "SSD" ? "internaldrive" : "externaldrive")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(drive.name)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(formatBytes(drive.totalBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DriveUsageBar(percent: drive.usedPercent)
                            .frame(width: 60)
                    }
                }
            }
        }
    }
}

struct DriveUsageBar: View {
    let percent: Double

    var color: Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .blue
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.separatorColor))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * min(percent / 100, 1.0))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Storage Overview Card

struct StorageOverviewCard: View {
    private var totalUsed: Int64 { mockDrives.reduce(0) { $0 + $1.usedBytes } }
    private var totalCapacity: Int64 { mockDrives.reduce(0) { $0 + $1.totalBytes } }
    private var percent: Double { Double(totalUsed) / Double(totalCapacity) * 100 }

    var body: some View {
        DashboardCard(title: "Storage Overview", icon: "chart.pie", color: .blue) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color(.separatorColor), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: percent / 100)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(String(format: "%.0f%%", percent))
                            .font(.title2.bold().monospacedDigit())
                        Text("Used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 90)

                HStack(spacing: 16) {
                    VStack {
                        Text(formatBytes(totalUsed))
                            .font(.caption.bold().monospacedDigit())
                        Text("Used")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(formatBytes(totalCapacity - totalUsed))
                            .font(.caption.bold().monospacedDigit())
                        Text("Free")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Integrity Card

struct IntegrityCard: View {
    var body: some View {
        DashboardCard(title: "Integrity Status", icon: "checkmark.shield", color: .green) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)

                Text("All verified")
                    .font(.callout.weight(.medium))

                VStack(spacing: 4) {
                    HStack {
                        Text("Last check:")
                        Spacer()
                        Text("2 hours ago")
                    }
                    HStack {
                        Text("Files verified:")
                        Spacer()
                        Text("596,045")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Mismatches:")
                        Spacer()
                        Text("0")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recent Activity Card

struct RecentActivityCard: View {
    var body: some View {
        DashboardCard(title: "Recent Activity", icon: "clock", color: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                ActivityRow(icon: "externaldrive.fill", text: "B SSD connected", time: "2h ago", color: .green)
                ActivityRow(icon: "doc.text.magnifyingglass", text: "Scan completed: A SSD", time: "2h ago", color: .blue)
                ActivityRow(icon: "arrow.left.arrow.right", text: "Transfer: 1,240 files to C SSD", time: "1d ago", color: .purple)
                ActivityRow(icon: "checkmark.shield", text: "Integrity check passed", time: "1d ago", color: .green)
                ActivityRow(icon: "externaldrive.badge.minus", text: "1 HDD disconnected", time: "3d ago", color: .gray)
            }
        }
    }
}

struct ActivityRow: View {
    let icon: String
    let text: String
    let time: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.caption)
            Spacer()
            Text(time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Drive List Card

struct DriveListCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("All Drives", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Button("Add Drive") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            ForEach(mockDrives) { drive in
                HStack(spacing: 14) {
                    // Status dot
                    Circle()
                        .fill(drive.isMounted ? .green : .gray.opacity(0.4))
                        .frame(width: 8, height: 8)

                    Image(systemName: drive.mediaType == "SSD" ? "internaldrive" : "externaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.name)
                            .font(.callout.weight(.medium))
                        Text("\(formatCount(drive.fileCount)) files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let scan = drive.lastScan {
                        Text("Scanned \(scan)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    DriveUsageBar(percent: drive.usedPercent)
                        .frame(width: 80)

                    Text(String(format: "%.0f%%", drive.usedPercent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 35, alignment: .trailing)

                    Text(formatBytes(drive.totalBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.controlBackgroundColor))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Dashboard Card Container

struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useTB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatCount(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}

#Preview {
    DriveDashboard()
        .frame(width: 800, height: 700)
}
