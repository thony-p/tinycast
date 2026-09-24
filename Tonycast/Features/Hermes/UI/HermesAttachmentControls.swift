import AppKit
import SwiftUI

/// Presents the file panels the attach menu opens.
///
/// A panel rather than a drag-and-drop target: the agent reads paths, and a panel hands back real
/// ones for files the user can also see in Finder. Runs as a sheet on the Hermes window so it is
/// unambiguously modal to the chat it will attach to.
@MainActor
enum ACPAttachmentPicker {
    static func present(_ source: ACPAttachmentSource) -> [String] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = source.allowsMultiple
        panel.canChooseDirectories = source.choosesDirectories
        panel.canChooseFiles = !source.choosesDirectories
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        panel.message = "Choose what Hermes should read."
        // An empty filter means everything the agent can read, not "nothing", so the property is
        // only set when this source narrows the choice.
        let types = source.contentTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }
}

/// The composer's `+`: a menu of what can be attached, mirroring Hermes Desktop's attach menu.
struct HermesAttachButton: View {
    let isEnabled: Bool
    let onSource: (ACPAttachmentSource) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(ACPAttachmentSource.allCases) { source in
                Button {
                    onSource(source)
                } label: {
                    Label(source.title, systemImage: source.symbolName)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
                        .fill(isHovering && isEnabled ? Theme.Colors.controlSurface : Color.clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help("Attach files, a folder, or images")
    }
}

/// The files staged for the next prompt, above the text field.
struct HermesAttachmentBar: View {
    let attachments: [ACPAttachment]
    let onRemove: (ACPAttachment) -> Void

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    chip(attachment)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ attachment: ACPAttachment) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: attachment.kind.symbolName)
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(attachment.name)
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove(attachment)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.name)")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
                .fill(Theme.Colors.controlSurface))
        .help(attachment.path)
    }
}

/// The connection's own chip: shows which Hermes, and changes it.
///
/// Sits beside New Session because that is where the choice matters — switching host discards the
/// current conversation, so it belongs next to the control that starts one.
struct HermesConnectionMenu: View {
    let connection: HermesConnection
    let isEnabled: Bool
    let onSelect: (HermesConnection) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(HermesConnection.catalog) { option in
                Button {
                    onSelect(option)
                } label: {
                    // The checkmark states the current host without a second label to read.
                    Label(
                        "\(option.name) — \(option.detail)",
                        systemImage: option == connection ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(connection.name)
                    .font(Font.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
                    .fill(isHovering && isEnabled ? Theme.Colors.controlSurface : Color.clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help("Choose which Hermes to talk to")
    }
}
