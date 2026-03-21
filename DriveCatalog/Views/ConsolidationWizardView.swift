import SwiftUI

/// Step-by-step consolidation wizard presented as a sheet from DriveListView.
struct ConsolidationWizardView: View {
    enum WizardStep {
        case analyzing       // Loading candidates from API
        case selectDrive     // User picks a source drive to consolidate
        case reviewPlan      // Shows migration plan details, user confirms
        case executing       // Live progress during migration
        case completed       // Summary of results
    }

    @State private var step: WizardStep = .analyzing
    @State private var candidates: [ConsolidationCandidate] = []
    @State private var consolidatableCount: Int = 0
    @State private var selectedCandidate: ConsolidationCandidate?
    @State private var plan: MigrationPlanSummary?
    @State private var planDetails: MigrationPlanResponse?
    @State private var validationResult: ValidatePlanResponse?
    @State private var migrationFiles: [MigrationFileResponse] = []
    @State private var operation: OperationResponse?
    @State private var error: String?
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Step content
            Group {
                switch step {
                case .analyzing:
                    analyzingView
                case .selectDrive:
                    selectDriveView
                case .reviewPlan:
                    reviewPlanView
                case .executing:
                    executingView
                case .completed:
                    completedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            await loadCandidates()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drive Consolidation")
                    .font(.headline)
                Text(stepTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if step != .executing {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    private var stepTitle: String {
        switch step {
        case .analyzing: return "Analyzing drives..."
        case .selectDrive: return "Select a drive to consolidate"
        case .reviewPlan: return "Review migration plan"
        case .executing: return "Migration in progress"
        case .completed:
            if let details = planDetails {
                switch details.status {
                case "completed": return "Migration complete"
                case "cancelled": return "Migration cancelled"
                default: return "Migration failed"
                }
            }
            return "Migration complete"
        }
    }

    // MARK: - Step 1: Analyzing

    private var analyzingView: some View {
        VStack(spacing: 16) {
            if let error {
                errorDisplay(message: error) {
                    Task { await loadCandidates() }
                }
            } else {
                Spacer()
                ProgressView("Loading consolidation candidates...")
                    .controlSize(.large)
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Step 2: Select Drive

    private var selectDriveView: some View {
        VStack(spacing: 0) {
            if consolidatableCount == 0 {
                noCandidatesView
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(candidates) { candidate in
                            candidateCard(candidate)
                        }
                    }
                    .padding()
                }
            }

            if isLoading {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating migration plan...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            if let error {
                Divider()
                errorBanner(message: error)
            }
        }
    }

    private var noCandidatesView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No Drives Can Be Consolidated")
                .font(.title2)
                .fontWeight(.semibold)
            Text("All drives contain unique files that cannot fit on other drives, or there are not enough drives for consolidation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func candidateCard(_ candidate: ConsolidationCandidate) -> some View {
        Button {
            guard candidate.isCandidate, !isLoading else { return }
            Task { await selectCandidate(candidate) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "externaldrive")
                        .font(.title2)
                        .foregroundStyle(candidate.isCandidate ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.driveName)
                            .font(.headline)
                            .foregroundStyle(candidate.isCandidate ? .primary : .secondary)
                        Text("\(candidate.totalFiles) files (\(Self.formatBytes(candidate.totalSizeBytes)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if candidate.isCandidate {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    statLabel("Unique", value: "\(candidate.uniqueFiles) files", detail: Self.formatBytes(candidate.uniqueSizeBytes))
                    statLabel("Duplicated", value: "\(candidate.duplicatedFiles) files", detail: Self.formatBytes(candidate.duplicatedSizeBytes))
                    statLabel("Reclaimable", value: Self.formatBytes(candidate.reclaimableBytes), detail: nil)
                }

                if candidate.isCandidate {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Target drives: \(candidate.targetDrives.map { "\($0.driveName) (\(Self.formatBytes($0.freeBytes)) free)" }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text("Cannot consolidate: unique files do not fit on available target drives")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(candidate.isCandidate ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(candidate.isCandidate ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!candidate.isCandidate || isLoading)
    }

    private func statLabel(_ title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 3: Review Plan

    private var reviewPlanView: some View {
        VStack(spacing: 0) {
            if let plan, let planDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Plan summary
                        planSummarySection(plan: plan, details: planDetails)

                        Divider()

                        // File status breakdown
                        fileStatusSection(details: planDetails)

                        Divider()

                        // File list
                        fileListSection
                    }
                    .padding()
                }

                Divider()

                // Validation result / error
                if let validationResult, !validationResult.valid {
                    validationErrorBanner(validation: validationResult)
                }

                if let error {
                    errorBanner(message: error)
                }

                // Action buttons
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        Task { await validateAndExecute() }
                    } label: {
                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Validating...")
                            }
                        } else {
                            Text("Validate & Confirm")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                }
                .padding()
            }
        }
    }

    private func planSummarySection(plan: MigrationPlanSummary, details: MigrationPlanResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Migration Plan")
                .font(.title3)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Source Drive:")
                        .foregroundStyle(.secondary)
                    Text(plan.sourceDrive)
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Total Files:")
                        .foregroundStyle(.secondary)
                    Text("\(plan.totalFiles)")
                }
                GridRow {
                    Text("Files to Copy:")
                        .foregroundStyle(.secondary)
                    Text("\(plan.filesToCopy)")
                }
                GridRow {
                    Text("Delete Only:")
                        .foregroundStyle(.secondary)
                    Text("\(plan.filesToDelete)")
                }
                GridRow {
                    Text("Bytes to Transfer:")
                        .foregroundStyle(.secondary)
                    Text(Self.formatBytes(plan.totalBytesToTransfer))
                        .fontWeight(.medium)
                }
            }
        }
    }

    private func fileStatusSection(details: MigrationPlanResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Breakdown by Target")
                .font(.title3)
                .fontWeight(.semibold)

            // Group files by target drive
            let filesByTarget = Dictionary(grouping: migrationFiles) { $0.targetDriveName ?? "Delete Only" }

            ForEach(Array(filesByTarget.keys.sorted()), id: \.self) { targetName in
                if let files = filesByTarget[targetName] {
                    let totalBytes = files.reduce(Int64(0)) { $0 + $1.sourceSizeBytes }
                    HStack {
                        Image(systemName: targetName == "Delete Only" ? "trash" : "externaldrive")
                            .foregroundStyle(targetName == "Delete Only" ? .red : .blue)
                        VStack(alignment: .leading) {
                            Text(targetName)
                                .fontWeight(.medium)
                            Text("\(files.count) files, \(Self.formatBytes(totalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files (\(migrationFiles.count))")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(migrationFiles) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.lastPathComponent(file.sourcePath))
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.sourcePath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.formatBytes(file.sourceSizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(file.action == "copy_and_delete" ? "Copy" : "Delete")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(file.action == "copy_and_delete" ? Color.blue.opacity(0.1) : Color.red.opacity(0.1))
                                .cornerRadius(4)
                            if let target = file.targetDriveName {
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                Text(target)
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                if file.id != migrationFiles.last?.id {
                    Divider()
                }
            }
        }
    }

    private func validationErrorBanner(validation: ValidatePlanResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Validation Failed: Insufficient space on target drives")
                    .fontWeight(.medium)
            }
            ForEach(validation.targetSpace.filter { !$0.sufficient }) { target in
                Text("\(target.driveName): needs \(Self.formatBytes(target.bytesNeeded)), has \(Self.formatBytes(target.bytesAvailable))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
    }

    // MARK: - Step 4: Executing

    private var executingView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Progress overview
                    if let operation {
                        progressSection(operation: operation)
                    } else {
                        ProgressView("Starting migration...")
                            .padding()
                    }

                    Divider()

                    // Recent file activity
                    Text("Recent File Activity")
                        .font(.title3)
                        .fontWeight(.semibold)

                    ForEach(migrationFiles.prefix(50)) { file in
                        fileActivityRow(file: file)
                    }

                    if migrationFiles.isEmpty {
                        Text("Waiting for file processing...")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .padding()
            }

            Divider()

            // Cancel button
            HStack {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel Migration", role: .destructive) {
                    Task { await cancelCurrentMigration() }
                }
                .disabled(isLoading)
            }
            .padding()
        }
        .task {
            await pollMigration()
        }
    }

    private func progressSection(operation: OperationResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Migration Progress")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if let eta = operation.etaSeconds, eta > 0 {
                    Text("ETA: \(Self.formatDuration(eta))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let percent = operation.progressPercent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(Int(percent))%")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(operation.filesProcessed) / \(operation.filesTotal) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                HStack {
                    Text("\(operation.filesProcessed) / \(operation.filesTotal) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func fileActivityRow(file: MigrationFileResponse) -> some View {
        HStack(spacing: 8) {
            fileStatusIcon(status: file.status)

            VStack(alignment: .leading, spacing: 1) {
                Text(Self.lastPathComponent(file.sourcePath))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = file.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(Self.formatBytes(file.sourceSizeBytes))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fileStatusIcon(status: String) -> some View {
        switch status {
        case "pending":
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case "copying", "verifying":
            ProgressView()
                .controlSize(.mini)
        case "deleted", "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Step 5: Completed

    private var completedView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 20)

                    completionIcon

                    if let details = planDetails {
                        completionStats(details: details)

                        if !details.errors.isEmpty {
                            DisclosureGroup("Errors (\(details.errors.count))") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(details.errors, id: \.self) { err in
                                        Text(err)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .padding(.horizontal)
                        }
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var completionIcon: some View {
        if let details = planDetails {
            switch details.status {
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Migration Complete")
                    .font(.title2)
                    .fontWeight(.semibold)
            case "cancelled":
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Migration Cancelled")
                    .font(.title2)
                    .fontWeight(.semibold)
            default:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Migration Failed")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        }
    }

    private func completionStats(details: MigrationPlanResponse) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("Files Completed:")
                    .foregroundStyle(.secondary)
                Text("\(details.filesCompleted)")
                    .fontWeight(.medium)
            }
            GridRow {
                Text("Bytes Transferred:")
                    .foregroundStyle(.secondary)
                Text(Self.formatBytes(details.bytesTransferred))
                    .fontWeight(.medium)
            }
            GridRow {
                Text("Files Failed:")
                    .foregroundStyle(.secondary)
                Text("\(details.filesFailed)")
                    .fontWeight(.medium)
                    .foregroundStyle(details.filesFailed > 0 ? .red : .primary)
            }
        }
    }

    // MARK: - Shared Components

    private func errorDisplay(message: String, retryAction: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                self.error = nil
                retryAction()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("Dismiss") {
                self.error = nil
            }
            .font(.caption)
        }
        .padding()
        .background(Color.red.opacity(0.05))
    }

    // MARK: - Actions

    private func loadCandidates() async {
        error = nil
        do {
            let response = try await APIService.shared.fetchConsolidationCandidates()
            candidates = response.candidates
            consolidatableCount = response.consolidatableCount
            step = .selectDrive
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectCandidate(_ candidate: ConsolidationCandidate) async {
        selectedCandidate = candidate
        isLoading = true
        error = nil

        do {
            // 1. Generate migration plan
            let generatedPlan = try await APIService.shared.generateMigrationPlan(sourceDrive: candidate.driveName)
            plan = generatedPlan

            // 2. Fetch full plan details
            let details = try await APIService.shared.fetchMigrationPlan(planId: generatedPlan.planId)
            planDetails = details

            // 3. Fetch file list
            let filesResponse = try await APIService.shared.fetchMigrationFiles(planId: generatedPlan.planId, limit: 200)
            migrationFiles = filesResponse.files

            isLoading = false
            step = .reviewPlan
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func validateAndExecute() async {
        guard let plan else { return }
        isLoading = true
        error = nil
        validationResult = nil

        do {
            // Validate
            let validation = try await APIService.shared.validateMigrationPlan(planId: plan.planId)
            validationResult = validation

            if !validation.valid {
                isLoading = false
                return
            }

            // Execute
            let execResponse = try await APIService.shared.executeMigrationPlan(planId: plan.planId)
            _ = execResponse.operationId

            isLoading = false
            step = .executing
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func pollMigration() async {
        guard let plan else { return }

        while true {
            do {
                // Fetch updated plan details for operation ID and status
                let details = try await APIService.shared.fetchMigrationPlan(planId: plan.planId)
                planDetails = details

                // Poll operation if we have an ID
                if let opId = details.operationId {
                    let op = try await APIService.shared.fetchOperation(id: opId)
                    operation = op
                }

                // Fetch recent file activity
                let filesResponse = try await APIService.shared.fetchMigrationFiles(planId: plan.planId, limit: 50)
                migrationFiles = filesResponse.files

                // Check if done
                if details.status == "completed" || details.status == "failed" || details.status == "cancelled" {
                    // Fetch final state
                    planDetails = try await APIService.shared.fetchMigrationPlan(planId: plan.planId)
                    step = .completed
                    break
                }

                try await Task.sleep(for: .seconds(2))
            } catch {
                self.error = "Lost connection: \(error.localizedDescription)"
                break
            }
        }
    }

    private func cancelCurrentMigration() async {
        guard let plan else { return }
        isLoading = true
        do {
            try await APIService.shared.cancelMigration(planId: plan.planId)
            // Polling will detect the cancellation
        } catch {
            self.error = "Cancel failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Helpers

    /// Format bytes as human-readable string (1024-based).
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Format seconds as human-readable duration.
    static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    /// Extract the last path component from a file path.
    static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
