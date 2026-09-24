import Foundation

/// A Hermes instance Tonycast can attach to: this Mac, or the homelab VM over SSH.
///
/// A connection is a launch recipe rather than a network client. `hermes acp` speaks the same
/// newline-delimited JSON-RPC over stdin/stdout either way, so the only difference between the two
/// is the command that starts it — and every layer above this one stays host-agnostic.
struct HermesConnection: Identifiable, Equatable, Sendable {
    let id: String
    /// What the picker lists and the header's "Connected" line names.
    let name: String
    /// What the connection actually is, for the picker's second line.
    let detail: String
    /// The executable to run: `hermes` locally, `ssh` for the VM.
    let command: String
    let arguments: [String]

    /// This Mac's own Hermes, resolved on PATH like every other tool Tonycast launches.
    static let local = HermesConnection(
        id: "local",
        name: "Mac",
        detail: "This Mac",
        command: "hermes",
        arguments: ["acp"])

    /// The homelab VM, reached over SSH.
    ///
    /// `-T` suppresses the pseudo-terminal: ACP needs a raw byte pipe, and a pty would rewrite
    /// newlines and swallow the framing. `BatchMode=yes` makes a missing key fail immediately with
    /// a readable reason instead of blocking on a prompt nobody can see inside the wire, and
    /// `ConnectTimeout` does the same for an unreachable host — without it ssh blocks in the TCP
    /// connect for over a minute, so the window would sit on "Starting Hermes…" with no explanation.
    static let vm = HermesConnection(
        id: "vm",
        name: "VM",
        detail: "hermes over SSH",
        command: "ssh",
        arguments: [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "hermes",
            "~/.local/bin/hermes acp",
        ])

    /// Offered in dispatch order; the first is the default for a fresh install.
    static let catalog: [HermesConnection] = [.local, .vm]

    static let fallback = HermesConnection.local

    /// The connection an id names, falling back to this Mac. An id from an older build, or one
    /// whose host no longer exists, must not leave the window with nothing to launch.
    static func named(_ id: String?) -> HermesConnection {
        guard let id, let match = catalog.first(where: { $0.id == id }) else { return fallback }
        return match
    }

    /// Whether this connection runs somewhere other than this Mac, which is what decides if a
    /// failure is worth explaining as a remote-host problem.
    var isRemote: Bool { self != Self.local }
}
