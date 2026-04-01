import SwiftUI

/// Shown on first launch — requires beta invite code + name + email to use the app.
struct BetaRegistrationView: View {
    @ObservedObject var beta = BetaService.shared
    @State private var code = ""
    @State private var name = ""
    @State private var email = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Catalog")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Beta Access")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Form
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invite Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("XXXX-XXXX", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Your name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Email")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("your@email.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 300)

            // Error
            if let error = beta.registrationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Submit
            Button {
                isSubmitting = true
                Task {
                    await beta.register(code: code, name: name, email: email)
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    Text("Activate Beta")
                        .frame(width: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.isEmpty || name.isEmpty || email.isEmpty || isSubmitting)

            // Footer
            Text("Your data is only used for beta management.\nNo tracking, no ads.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(width: 440, height: 560)
    }
}
