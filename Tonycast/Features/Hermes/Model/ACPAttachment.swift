import Foundation
import UniformTypeIdentifiers

/// A file, image or folder the user attached to a prompt.
///
/// The attachment holds the path, never the bytes: the agent reads what it needs itself through the
/// `resource_link` block. That is what keeps a 100 MB video out of Tonycast's memory and off the
/// wire, and it is why an attachment survives a re-render for free.
///
/// What the thing *is* (`kind`, `mimeType`) is decided once, when the user picks it. How big it is
/// now (`size`) is read at send time. Frozen identity beside a live measurement is deliberate: a
/// file replaced between staging and sending changes its size, not its nature.
struct ACPAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case image
        /// A directory. Hermes cannot inline one — it answers with an `Is a directory` note — so the
        /// path is the whole payload, and the agent follows it with its own tools.
        case folder

        var symbolName: String {
            switch self {
            case .image: return "photo"
            case .folder: return "folder"
            case .file: return "doc"
            }
        }
    }

    let id = UUID()
    /// The absolute path on the machine that will read it.
    let path: String
    let kind: Kind
    /// Resolved when the file was picked, so the block's type can never disagree with the icon the
    /// user saw. Nil for a folder, which has no MIME type.
    let mimeType: String?

    var name: String { (path as NSString).lastPathComponent }

    /// A `file://` URI, which is the only form Hermes resolves to a readable path.
    ///
    /// Built by `URL`, not by hand: percent-encoding a path is easy to get subtly wrong, and this
    /// gets it right by construction — a space becomes `%20`, a `#` or `?` becomes `%23`/`%3F`
    /// (so a filename can never truncate the URI or invent a query), slashes stay the separators
    /// they are, and non-ASCII encodes as UTF-8 per RFC 8089.
    var uri: String { URL(fileURLWithPath: path).absoluteString }

    /// The wire block: a `resource_link` the agent resolves and reads itself.
    ///
    /// `mimeType` is omitted for a folder — a directory has no MIME type, and claiming
    /// `application/octet-stream` would invite the agent into a byte read that cannot work.
    var wireBlock: [String: Any] {
        var block: [String: Any] = ["type": "resource_link", "uri": uri, "name": name]
        if let mimeType { block["mimeType"] = mimeType }
        if kind != .folder, let size = urlSize { block["size"] = size }
        return block
    }

    /// The file's size at send time, as an `Int`.
    private var urlSize: Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// Classifies a picked path and resolves its MIME type in one pass. Nil when the path is not
    /// one Tonycast can name: a relative path would be silently rooted at the process's own working
    /// directory, and `URL` reads the first segment of some spellings as a host — either way the
    /// agent would receive a link to the wrong file, so the attachment is refused instead.
    ///
    /// A leading `~/` is accepted and expanded, because `URL` expands exactly that form. The bare
    /// `~` is not: `URL` roots it at the working directory, which is a directory nobody asked for.
    ///
    /// Directory-ness is asked of the filesystem rather than the content type, because a symlinked
    /// directory (`/tmp` → `/private/tmp`) reports `public.symlink` and would otherwise be typed as
    /// a file. Images are then recognised by content type, so a renamed screenshot is still offered
    /// as an image.
    static func at(path: String) -> ACPAttachment? {
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        // Expanded up front so `path`, `uri` and `name` all describe the same file.
        let resolved = (path as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return ACPAttachment(path: resolved, kind: .folder, mimeType: nil)
        }

        let url = URL(fileURLWithPath: resolved)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let kind: Kind = (type?.conforms(to: .image) ?? false) ? .image : .file
        // Content type first, then the suffix, so a suffix-less or renamed file is typed by what
        // the system knows rather than by a guess from its name.
        let mime =
            type?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return ACPAttachment(
            path: resolved, kind: kind, mimeType: mime ?? "application/octet-stream")
    }

    /// Two attachments naming the same path are the same attachment. `id` is excluded deliberately:
    /// it exists for SwiftUI identity, and folding it in would make dedupe impossible.
    static func == (lhs: ACPAttachment, rhs: ACPAttachment) -> Bool {
        lhs.path == rhs.path && lhs.kind == rhs.kind
    }
}

/// What the attach menu offers, kept in the UI's dispatch order.
enum ACPAttachmentSource: String, CaseIterable, Identifiable, Sendable {
    case files
    case folder
    case images

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files…"
        case .folder: return "Folder…"
        case .images: return "Images…"
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "doc"
        case .folder: return "folder"
        case .images: return "photo"
        }
    }

    /// Whether the panel picks one item or many: a folder attachment is a single choice, because
    /// the agent follows the directory itself.
    var allowsMultiple: Bool { self != .folder }

    /// The panel's file-type filter, or nil to allow anything the agent can read.
    var contentTypes: [UTType] {
        switch self {
        case .files, .folder: return []
        case .images: return [.image]
        }
    }

    var choosesDirectories: Bool { self == .folder }
}
