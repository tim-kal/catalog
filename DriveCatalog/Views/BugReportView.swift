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
                    Text("Bug report submitted!")
                        .font(.headline)
                    Text("Thank you for helping improve Catalog.")
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
                }

                HStack {
                    Spacer()
                    Button {
                        isSubmitting = true
                        Task {
                            let success = await beta.submitBugReport(
                                title: title,
                                description: description,
                                includeLog: includeLog
                            )
                            isSubmitting = false
                            if success { submitted = true }
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
        .frame(width: 450, height: 400)
    }
}
