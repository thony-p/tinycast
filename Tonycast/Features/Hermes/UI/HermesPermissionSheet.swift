import SwiftUI

/// The approval prompt.
///
/// This is why a launcher hosting an agent is more than a chat wrapper: Hermes asks here before it
/// runs something dangerous, and the answer is a real decision. The option list arrives already
/// narrowed by `ACPPermissionBroker`, so a destructive command never shows a session-scoped grant.
/// Deny is the default action, not Allow.
struct HermesPermissionSheet: View {
    let request: ACPClient.PermissionRequest
    let options: [ACPClient.PermissionOption]
    let onDecide: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text("Hermes needs permission")
                    .font(Theme.Typography.panelTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            Text(request.title)
                .font(Font.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Colors.controlSurface))
            }

            // Deny takes the default action so Return never grants a permission by accident.
            HStack(spacing: Theme.Spacing.md) {
                Button("Deny") { onDecide(nil) }
                    .keyboardShortcut(.defaultAction)
                Spacer(minLength: Theme.Spacing.md)
                ForEach(options, id: \.optionID) { option in
                    Button(option.name) { onDecide(option.optionID) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .background(Theme.Colors.sheen)
    }
}
