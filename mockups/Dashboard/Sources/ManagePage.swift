import SwiftUI

// MARK: - Manage Page (3 tabs per D2)

struct ManagePage: View {
    @State private var selectedTab: ManageTab = .backups

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(ManageTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.title)
                        }
                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1))
                                : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider()
                .padding(.top, 8)

            // Tab content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .backups:
                        BackupStatusTab()
                    case .duplicates:
                        DuplicatesTab()
                    case .actions:
                        RecommendedActionsTab()
                    }
                }
                .padding(20)
            }
        }
    }
}

enum ManageTab: String, CaseIterable {
    case backups, duplicates, actions

    var title: String {
        switch self {
        case .backups: return "Backup Status"
        case .duplicates: return "Duplicates"
        case .actions: return "Recommended Actions"
        }
    }

    var icon: String {
        switch self {
        case .backups: return "shield.checkered"
        case .duplicates: return "doc.on.doc"
        case .actions: return "lightbulb"
        }
    }
}

// MARK: - Backup Status Tab

struct BackupStatusTab: View {
    var body: some View {
        VStack(spacing: 16) {
            // Per-drive backup status
            ForEach(mockDrives) { drive in
                HStack(spacing: 14) {
                    Image(systemName: drive.isMounted ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(drive.isMounted ? .green : .gray)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(drive.name)
                            .font(.callout.weight(.medium))
                        Text(drive.isMounted ? "Connected — last backed up 2d ago" : "Disconnected — last seen 3d ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if drive.isMounted {
                        Button("Backup Now") {}
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.controlBackgroundColor))
                )
            }

            // Folder-level backup highlight
            DashboardCard(title: "Unprotected Folders", icon: "exclamationmark.triangle", color: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    FolderBackupRow(path: "A SSD/DCIM/2026-03", files: 1240, status: .noCopy)
                    FolderBackupRow(path: "B SSD/Video/Project X", files: 82, status: .noCopy)
                    FolderBackupRow(path: "LX 1TB/Imports/March", files: 3400, status: .partial)
                }
            }
        }
    }
}

enum BackupStatus {
    case backed, partial, noCopy
}

struct FolderBackupRow: View {
    let path: String
    let files: Int
    let status: BackupStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .noCopy ? "xmark.circle" : "minus.circle")
                .foregroundStyle(status == .noCopy ? .red : .orange)
                .frame(width: 16)
            Text(path)
                .font(.caption.weight(.medium))
            Spacer()
            Text("\(files) files")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(status == .noCopy ? "No copies" : "Partial")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(status == .noCopy ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                )
                .foregroundStyle(status == .noCopy ? .red : .orange)
        }
    }
}

// MARK: - Duplicates Tab

struct DuplicatesTab: View {
    var body: some View {
        VStack(spacing: 16) {
            // Summary cards
            HStack(spacing: 16) {
                SummaryCard(value: "4,821", label: "Duplicate Files", icon: "doc.on.doc", color: .orange)
                SummaryCard(value: "128 GB", label: "Reclaimable Space", icon: "arrow.down.circle", color: .green)
                SummaryCard(value: "342", label: "Duplicate Folders", icon: "folder.badge.minus", color: .blue)
            }

            // Duplicate groups
            DashboardCard(title: "Largest Duplicate Groups", icon: "arrow.triangle.2.circlepath", color: .orange) {
                VStack(spacing: 10) {
                    DuplicateGroupRow(name: "IMG_4521.CR3", size: "45 MB", copies: 3, drives: ["A SSD", "B SSD", "1 HDD"])
                    DuplicateGroupRow(name: "Wedding_Final_v3.mov", size: "12.4 GB", copies: 2, drives: ["B SSD", "C SSD"])
                    DuplicateGroupRow(name: "Lightroom Catalog.lrcat", size: "890 MB", copies: 4, drives: ["A SSD", "B SSD", "C SSD", "LX 1TB"])
                    DuplicateGroupRow(name: "DJI_0042.MP4", size: "8.2 GB", copies: 2, drives: ["1 HDD", "B SSD"])
                }
            }
        }
    }
}

struct SummaryCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor))
        )
    }
}

struct DuplicateGroupRow: View {
    let name: String
    let size: String
    let copies: Int
    let drives: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.medium))
                Text(drives.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(size)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(copies) copies")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Recommended Actions Tab

struct RecommendedActionsTab: View {
    var body: some View {
        VStack(spacing: 16) {
            DashboardCard(title: "Recommended Actions", icon: "lightbulb", color: .yellow) {
                VStack(spacing: 12) {
                    ActionRow(
                        priority: .high,
                        title: "Back up A SSD/DCIM/2026-03",
                        detail: "1,240 files with no copies on any other drive",
                        action: "Transfer"
                    )
                    ActionRow(
                        priority: .medium,
                        title: "Remove duplicates from 1 HDD",
                        detail: "4,200 files (48 GB) already exist on B SSD with matching hashes",
                        action: "Review"
                    )
                    ActionRow(
                        priority: .medium,
                        title: "Consolidate LX 1TB → B SSD",
                        detail: "All 18,220 files fit on B SSD (1.1 TB free). Drive can be retired.",
                        action: "Plan"
                    )
                    ActionRow(
                        priority: .low,
                        title: "Re-scan C SSD",
                        detail: "Last scanned 3 days ago. 12 files may have changed.",
                        action: "Scan"
                    )
                }
            }
        }
    }
}

enum ActionPriority {
    case high, medium, low

    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        }
    }
}

struct ActionRow: View {
    let priority: ActionPriority
    let title: String
    let detail: String
    let action: String

    var body: some View {
        HStack(spacing: 12) {
            Text(priority.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(priority.color))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action) {}
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

#Preview("Manage Page") {
    ManagePage()
        .frame(width: 800, height: 600)
}
