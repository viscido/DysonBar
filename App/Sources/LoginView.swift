import SwiftUI

struct LoginView: View {
    @ObservedObject var flow: LoginFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.image())
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to your Dyson account")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The same account you use in the MyDyson app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            switch flow.step {
            case .email: emailStep
            case .code: codeStep
            case .device: deviceStep
            }

            if let error = flow.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Your password is sent once to Dyson to sign in and is never stored. "
                 + "Only the session token is kept, in your macOS Keychain.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
        .disabled(flow.busy)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $flow.email)
                .textContentType(.username)
            HStack {
                TextField("Country", text: $flow.country)
                    .frame(width: 60)
                Text("Country of your Dyson account (ISO code, e.g. IT, DE, GB, US)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                if flow.busy { ProgressView().controlSize(.small) }
                Button("Send code") { flow.requestCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canRequestCode)
                    .help("Emails a one-time code. Dyson limits how many codes you can request.")
            }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dyson emailed a one-time code to \(flow.normalizedEmail)"
                 + (flow.codeSentAt.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                 + ". It may take a minute to arrive — check spam too.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code from the email", text: $flow.code)
                .textContentType(.oneTimeCode)
            SecureField("Dyson account password", text: $flow.password)
                .textContentType(.password)
            HStack {
                Button("Back") { flow.back() }
                Button("Send a new code") { flow.requestCode(forceNew: true) }
                    .disabled(flow.busy || flow.isBlocked)
                    .help("Only if the first email never arrived: Dyson limits code requests.")
                Spacer()
                if flow.busy { ProgressView().controlSize(.small) }
                Button("Sign in") { flow.verify() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canVerify)
            }
        }
    }

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose the device to control:")
                .font(.system(size: 12))
            ForEach(flow.devices) { device in
                Button {
                    flow.choose(device)
                } label: {
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text(device.model ?? device.topicRoot)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("You can switch later from the menu-bar icon's right-click menu.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
