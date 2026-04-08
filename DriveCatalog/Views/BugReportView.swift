import SwiftUI

/// Bug report sheet — accessible from Settings.
struct BugReportView: View {
    @ObservedObject var beta = BetaService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var includeLog = true
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var submissionHeadline = "Bug report submitted!"
    @State private var submissionDetail = "Thank you for helping improve Catalog."
    @State private var submitError: String?
    @State private var recentErrors: [ErrorLogEntry] = []

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Report a Bug")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }

            if submitted {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text(submissionHeadline)
                        .font(.headline)
                    Text(submissionDetail)
                        .foregroundStyle(.secondary)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What went wrong?", text: $title)
                        .textFieldStyle(.roundedBorder)

                    Text("Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.2))
                        .font(.system(.body, design: .monospaced))

                    Toggle("Include backend log (helps us debug)", isOn: $includeLog)
                        .font(.caption)

                    if !recentErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recent errors (auto-included)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(recentErrors.prefix(5)) { entry in
                                HStack(spacing: 4) {
                                    Text(entry.code)
                                        .font(.system(.caption2, design: .monospaced))
                                    Text(entry.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let submitError {
                        Text(submitError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        isSubmitting = true
                        submitError = nil
                        Task {
                            let result = await beta.submitBugReport(
                                title: title,
                                description: description,
                                includeLog: includeLog
                            )
                            isSubmitting = false
                            switch result {
                            case .backend:
                                submissionHeadline = "Bug report submitted!"
                                submissionDetail = "Thank you for helping improve Catalog."
                                submitted = true
                            case .githubDraft:
                                submissionHeadline = "GitHub issue draft opened"
                                submissionDetail = "The beta endpoint is unavailable. Please click Submit on the opened GitHub page."
                                submitted = true
                            case .failed:
                                submitError = "Could not submit report. Please try again."
                            }
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Submit Report")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty || isSubmitting)
                }
            }
        }
        .padding(20)
        .frame(width: 450, height: 420)
        .task {
            recentErrors = (try? await APIService.shared.fetchErrors(limit: 10)) ?? []
        }
    }
}
