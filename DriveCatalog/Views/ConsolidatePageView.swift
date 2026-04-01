import SwiftUI

/// Landing page for drive consolidation — explains the feature and shows
/// data-driven analysis before the user can start anything.
struct ConsolidatePageView: View {
    @Environment(\.activeTab) private var activeTab
    @EnvironmentObject private var backend: BackendService

    @State private var candidates: [ConsolidationCandidate] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showWizard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Label("Drive Consolidation", systemImage: "arrow.triangle.merge")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Free up entire drives by moving their unique files to other drives that have space. Files that already exist on other drives are safely deleted from the source.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                // How it works
                howItWorksSection

                Divider()

                // Analysis
                if !backend.isRunning {
                    notReadyView
                } else if isLoading {
                    loadingView
                } else if let error {
                    errorView(error)
                } else if candidates.isEmpty {
                    noCandidatesView
                } else {
                    candidatesSection
                }
            }
            .padding(24)
        }
        .task {
            if candidates.isEmpty, let cached = ViewCache.load([ConsolidationCandidate].self, key: "consolidation") {
                candidates = cached
            }
            if backend.isRunning {
                await loadCandidates()
            }
        }
        .onChange(of: activeTab) { _, newTab in
            if newTab == .consolidate && backend.isRunning {
                Task { await loadCandidates() }
            }
        }
        .sheet(isPresented: $showWizard) {
            ConsolidationWizardView()
        }
    }

    // MARK: - How It Works

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)

            step(number: 1, icon: "magnifyingglass", title: "Analyze",
                 detail: "Scans your drives to find which files are unique and which are duplicated across drives.")
            step(number: 2, icon: "list.bullet.clipboard", title: "Plan",
                 detail: "Creates a detailed plan showing exactly which files will be copied where, and what will be deleted. Nothing happens until you approve.")
            step(number: 3, icon: "checkmark.shield", title: "Verify & Execute",
                 detail: "Copies each file, verifies the hash matches, and only then deletes the source. If any hash doesn't match, the file is kept safe.")
            step(number: 4, icon: "externaldrive.badge.checkmark", title: "Result",
                 detail: "The source drive is emptied and can be repurposed or retired. Every action is logged in the audit trail.")

            // Safety note
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safety guarantees")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("No file is ever deleted without a verified copy existing elsewhere. You can cancel at any point and all progress is saved. Every operation is recorded in the audit log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
        }
    }

    private func step(number: Int, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Analysis Results

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your drives")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadCandidates() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            let consolidatable = candidates.filter { $0.isCandidate }
            let nonConsolidatable = candidates.filter { !$0.isCandidate }

            if !consolidatable.isEmpty {
                Text("\(consolidatable.count) drive\(consolidatable.count == 1 ? "" : "s") can be consolidated:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(consolidatable, id: \.driveName) { candidate in
                    candidateRow(candidate, consolidatable: true)
                }

                Button {
                    showWizard = true
                } label: {
                    Label("Start Consolidation Wizard", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No drives can be fully consolidated right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !nonConsolidatable.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Not consolidatable")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                ForEach(nonConsolidatable, id: \.driveName) { candidate in
                    candidateRow(candidate, consolidatable: false)
                }
            }
        }
    }

    private func candidateRow(_ candidate: ConsolidationCandidate, consolidatable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: consolidatable ? "externaldrive.fill.badge.minus" : "externaldrive.fill")
                .foregroundStyle(consolidatable ? .orange : .secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.driveName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack(spacing: 12) {
                    Text("\(candidate.totalFiles) files")
                        .font(.caption)
                    Text("\(candidate.uniqueFiles) unique")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("\(candidate.duplicatedFiles) duplicated")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if candidate.reclaimableBytes > 0 {
                        Text("\(formatBytes(candidate.reclaimableBytes)) reclaimable")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .foregroundStyle(.secondary)

                if !consolidatable {
                    Text("Unique files don't fit on available drives")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if consolidatable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
    }

    // MARK: - States

    private var notReadyView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for backend...")
                .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Analyzing drives...")
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text("Failed to analyze drives")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Retry") {
                Task { await loadCandidates() }
            }
        }
    }

    private var noCandidatesView: some View {
        VStack(spacing: 8) {
            Text("No drives found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Register and scan drives first from the Drives page.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data Loading

    private func loadCandidates() async {
        if candidates.isEmpty { isLoading = true }
        error = nil
        do {
            let response = try await APIService.shared.fetchConsolidationCandidates()
            candidates = response.candidates
            ViewCache.save(candidates, key: "consolidation")
        } catch {
            if candidates.isEmpty {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
