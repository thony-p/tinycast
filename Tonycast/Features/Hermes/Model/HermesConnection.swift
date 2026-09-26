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

    /// The SSH host a remote connection reaches, and nil for this Mac.
    ///
    /// Stated separately from `arguments` because a second, short-lived command runs on the same
    /// host: `hermes acp` is the long-lived wire, but the project listing is a read-only script,
    /// and
    /// it has to run on the host the *session* lives on rather than on whichever Mac the window is
    /// on.
    let hostAlias: String?

    /// This Mac's own Hermes, resolved on PATH like every other tool Tonycast launches.
    static let local = HermesConnection(
        id: "local",
        name: "Mac",
        detail: "This Mac",
        command: "hermes",
        arguments: ["acp"],
        hostAlias: nil)

    /// The homelab VM, reached over SSH.
    ///
    /// `-T` suppresses the pseudo-terminal: ACP needs a raw byte pipe, and a pty would rewrite
    /// newlines and swallow the framing. `BatchMode=yes` makes a missing key fail immediately with
    /// a readable reason instead of blocking on a prompt nobody can see inside the wire, and
    /// `ConnectTimeout` does the same for an unreachable host — without it ssh blocks in the TCP
    /// connect for over a minute, so the window would sit on "Starting Hermes…" with no
    /// explanation.
    static let vm = HermesConnection(
        id: "vm",
        name: "VM",
        detail: "hermes over SSH",
        command: "ssh",
        arguments: [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "hermes",
            "~/.local/bin/hermes acp",
        ],
        hostAlias: "hermes")

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

    /// How to run the project-listing script on this connection's own host, with the script
    /// arriving
    /// on standard input.
    ///
    /// A second launch recipe rather than a reuse of `command`/`arguments`: those describe the
    /// long-lived `hermes acp` wire, and this is a short read that must run where the *sessions*
    /// live.
    /// Locally that is the interpreter itself; for the VM it is the same interpreter over `ssh`, so
    /// no
    /// shell quoting is involved and no file is written on the far side.
    ///
    /// `/usr/bin/python3` is named absolutely because neither a non-login `ssh` command nor a
    /// Finder
    /// launch reads a shell rc file, so there is no PATH to fall back on. It is present at that
    /// path
    /// on macOS and on the Debian hosts this client talks to.
    var workspaceLaunch: (command: String, arguments: [String]) {
        guard let hostAlias else { return (Self.pythonInterpreter, ["-"]) }
        return (
            "ssh",
            [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", hostAlias,
                "\(Self.pythonInterpreter) -",
            ]
        )
    }

    static let pythonInterpreter = "/usr/bin/python3"
}
