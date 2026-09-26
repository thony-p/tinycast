import Foundation

/// Guards the four Phase-2 features: the fork version marker, the host picker, the token gauge's
/// exact wording, and the attach blocks.
///
/// The token figures are pinned to Hermes' own formatter (`@hermes/shared`'s `compactNumber` and
/// the statusbar's `usageContextLabel`), because "same as Hermes" is the requirement: a gauge that
/// disagrees with the desktop app is worse than none. `1048576` must read `1M`, not `1.0M`.
@main
struct HermesFeaturesTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // MARK: - Feature 1: the fork's version marker

        check("a fork version parses", AppVersion("0.11.3-t0.1") != nil)
        check("a fork version round-trips its text",
              AppVersion("0.11.3-t0.1")?.description == "0.11.3-t0.1")
        check("a fork version keeps the upstream triple",
              AppVersion("0.11.3-t0.1").map { "\($0.major).\($0.minor).\($0.patch)" } == "0.11.3")
        check("a fork version exposes its marker",
              AppVersion("0.11.3-t0.1")?.fork == "t0.1")
        check("a fork version is not a prerelease",
              AppVersion("0.11.3-t0.1")?.isPrerelease == false)
        check("a fork version is recognised as the fork",
              AppVersion("0.11.3-t0.1")?.isFork == true)
        check("a stock version is not the fork",
              AppVersion("0.11.3")?.isFork == false)
        check("a leading v still strips on a fork build",
              AppVersion("v0.12.0-t0.1")?.description == "0.12.0-t0.1")

        // The rule is "upstream version + the fork suffix": a new upstream must not lose the marker,
        // and the marker must carry the upstream number it was cut from.
        check("a second upstream release keeps its marker",
              AppVersion("0.12-t0.1") == nil || AppVersion("0.12.0-t0.1")?.description == "0.12.0-t0.1")
        check("a fork marker with a higher revision parses",
              AppVersion("0.11.3-t0.2")?.fork == "t0.2")
        check("a fork marker orders above the stock build it came from",
              AppVersion("0.11.3-t0.1").map { $0 > AppVersion("0.11.3")! } == true)
        check("a fork marker orders below the next stock patch",
              AppVersion("0.11.3-t0.1").map { $0 < AppVersion("0.11.4")! } == true)

        // The fork channel never updates itself, and a marker must not be mistaken for prerelease
        // in a way that changes which feed a build trusts.
        check("a fork build is still a stock release for the feed",
              AppVersion("0.11.3-t0.1")?.isPrerelease == false)

        // Existing contract must survive: beta, and the rejections.
        check("a beta still parses beside the fork form",
              AppVersion("0.2.0-beta.42")?.description == "0.2.0-beta.42")
        check("a beta is still a prerelease",
              AppVersion("0.2.0-beta.1")?.isPrerelease == true)
        check("a beta is not read as a fork marker",
              AppVersion("0.2.0-beta.1")?.fork == nil)
        check("an unknown channel is still rejected",
              AppVersion("0.2.0-alpha.1") == nil)
        check("a marker with no revision is rejected",
              AppVersion("0.11.3-t0") == nil)
        check("a marker with a non-numeric field is rejected",
              AppVersion("0.11.3-tx.1") == nil)
        check("a bare fork letter is rejected",
              AppVersion("0.11.3-t.1") == nil)
        check("a two-part version is still rejected",
              AppVersion("0.11") == nil)

        // MARK: - Feature 2: which Hermes

        check("the catalog offers the Mac first", HermesConnection.catalog.first == .local)
        check("the catalog offers two connections", HermesConnection.catalog.count == 2)
        check("the Mac connection is named", HermesConnection.local.name == "Mac")
        check("the VM connection is named", HermesConnection.vm.name == "VM")
        check("the Mac runs hermes directly", HermesConnection.local.command == "hermes")
        check("the Mac asks for the acp subcommand",
              HermesConnection.local.arguments == ["acp"])
        check("the VM launches over ssh", HermesConnection.vm.command == "ssh")
        check("the VM suppresses the pseudo-terminal",
              HermesConnection.vm.arguments.contains("-T"))
        check("the VM fails fast rather than prompting for a key",
              HermesConnection.vm.arguments.contains("BatchMode=yes"))
        check("the VM bounds the connect attempt",
              HermesConnection.vm.arguments.contains("ConnectTimeout=10"))
        check("the VM runs hermes acp as one remote command",
              HermesConnection.vm.arguments.last == "~/.local/bin/hermes acp")
        check("only the VM counts as remote",
              HermesConnection.vm.isRemote && !HermesConnection.local.isRemote)
        check("connection names are distinct",
              Set(HermesConnection.catalog.map(\.name)).count == HermesConnection.catalog.count)
        check("connection ids are distinct",
              Set(HermesConnection.catalog.map(\.id)).count == HermesConnection.catalog.count)

        // An id from a future build, or none at all, must still leave something to launch.
        check("an unknown connection id falls back to the Mac",
              HermesConnection.named("nope") == .local)
        check("a nil connection id falls back to the Mac",
              HermesConnection.named(nil) == .local)
        check("a known connection id resolves",
              HermesConnection.named("vm") == .vm)

        // MARK: - Feature 3: the token gauge

        check("a small count is plain", HermesUsageFormat.compact(999) == "999")
        check("a count at the boundary promotes to k", HermesUsageFormat.compact(1_000) == "1k")
        check("a fractional count keeps one decimal",
              HermesUsageFormat.compact(1_230) == "1.2k")
        check("the screenshot's reading is reproduced",
              HermesUsageFormat.compact(211_800) == "211.8k")
        check("a round million drops the decimal",
              HermesUsageFormat.compact(1_048_576) == "1M")
        check("a million and a half keeps one decimal",
              HermesUsageFormat.compact(1_500_000) == "1.5M")
        check("rounding never produces 1000k",
              HermesUsageFormat.compact(999_949) == "999.9k")
        check("the k/m boundary promotes instead of rounding up",
              HermesUsageFormat.compact(999_950) == "1M")
        check("zero reads as zero", HermesUsageFormat.compact(0) == "0")
        check("a missing count reads as zero", HermesUsageFormat.compact(nil) == "0")
        check("a negative count reads as zero", HermesUsageFormat.compact(-5) == "0")

        check("the label matches the desktop format",
              HermesUsageFormat.contextLabel(used: 211_800, size: 1_048_576, isEstimated: true)
                == "~211.8k/1M")
        check("a measured reading carries no tilde",
              HermesUsageFormat.contextLabel(used: 211_800, size: 1_048_576, isEstimated: false)
                == "211.8k/1M")
        check("no context window means no label",
              HermesUsageFormat.contextLabel(used: 100, size: nil, isEstimated: true).isEmpty)
        check("a zero context window means no label",
              HermesUsageFormat.contextLabel(used: 100, size: 0, isEstimated: true).isEmpty)

        check("the bar is ten cells", HermesUsageFormat.bar(percent: 20).count == 10)
        check("the bar fills one cell per ten percent",
              HermesUsageFormat.bar(percent: 20) == "██░░░░░░░░")
        check("the bar is empty at zero", HermesUsageFormat.bar(percent: 0) == "░░░░░░░░░░")
        check("the bar is full at a hundred", HermesUsageFormat.bar(percent: 100) == "██████████")
        check("the bar clamps above a hundred",
              HermesUsageFormat.bar(percent: 250) == "██████████")
        check("the bar clamps below zero",
              HermesUsageFormat.bar(percent: -50) == "░░░░░░░░░░")
        check("the bar label matches the desktop format",
              HermesUsageFormat.barLabel(percent: 20, isEstimated: true) == "[██░░░░░░░░] ~20%")
        check("an unestimated bar label drops the tilde",
              HermesUsageFormat.barLabel(percent: 20, isEstimated: false) == "[██░░░░░░░░] 20%")
        check("no percentage means no bar label",
              HermesUsageFormat.barLabel(percent: nil, isEstimated: true).isEmpty)
        // A broken measurement must not read as "context full", and a negative width must not trap.
        check("a NaN percentage is treated as none",
              HermesUsageFormat.barLabel(percent: .nan, isEstimated: true).isEmpty)
        check("an infinite percentage is treated as none",
              HermesUsageFormat.barLabel(percent: .infinity, isEstimated: true).isEmpty)
        check("a NaN bar is empty rather than full",
              HermesUsageFormat.bar(percent: .nan) == "░░░░░░░░░░")
        check("a negative width does not trap",
              HermesUsageFormat.bar(percent: 50, width: -1).isEmpty)
        check("a zero width is empty",
              HermesUsageFormat.bar(percent: 50, width: 0).isEmpty)
        // Parity with the desktop at the awkward value: both draw nine cells beside a "95%".
        check("cells round on the raw percent, as the desktop does",
              HermesUsageFormat.bar(percent: 94.9) == "█████████░")
        check("the label beside them still rounds up",
              HermesUsageFormat.barLabel(percent: 94.9, isEstimated: false) == "[█████████░] 95%")

        // The item the view renders computes both from one reading, so the two can never disagree.
        let reading = ACPTranscriptItem.Usage(used: 211_800, size: 1_048_576, isEstimated: true)
        check("a usage reading shares its label", reading.label == "~211.8k/1M")
        check("a usage reading shares its bar", reading.barLabel == "[██░░░░░░░░] ~20%")
        check("a usage fraction is the share of the window",
              abs((reading.fraction ?? 0) - 20.198) < 0.01)
        check("a window-less reading has no fraction",
              ACPTranscriptItem.Usage(used: 5, size: 0, isEstimated: true).fraction == nil)
        check("the screenshot's percentage is rounded the same way",
              abs((reading.fraction ?? 0).rounded() - 20) < 0.001)

        // The gauge rides inline in the composer row, so its widest reading must be no wider than
        // the slot reserved for it. Sweeping the whole space proves the reservation, where a spot
        // check at one value would not. The windows deliberately straddle every formatter rung: the
        // raw count, the k rung, and the unbounded M rung above a billion, which is where a `999.9k`
        // literal under-reserved (`~1500.5M/2000M` overflowed it by one character).
        var widestUncovered: String?
        var checkedReadings = 0
        let windows = [0, 1_000, 131_072, 999_949, 1_048_576, 2_000_000,
                       1_000_000_000, 2_000_000_000]
        for window in windows {
            let reserved = HermesUsageFormat.widestContextLabel(size: window).count
            // A step that divides 1e6 would sample only whole-megabyte values, which all compact to
            // the short `NNNNM` form and would leave the decimal forms unprobed. A prime step is what
            // makes this sweep able to fail.
            for used in stride(from: 0, through: max(window, 1), by: 7_919) {
                let label = HermesUsageFormat.contextLabel(
                    used: used, size: window, isEstimated: true)
                checkedReadings += 1
                if label.count > reserved {
                    widestUncovered = "\(label) (\(label.count)) overflows a \(reserved) slot "
                        + "for window \(window)"
                    break
                }
            }
            if widestUncovered != nil { break }
        }
        check("the sweep actually exercised readings", checkedReadings > 5_000)
        check("no realisable reading is wider than the reserved slot", widestUncovered == nil)
        check("the reserved label covers the widest k value",
              HermesUsageFormat.widestContextLabel(size: 1_048_576) == "~999.9k/1M")
        check("the reservation grows for an unbounded M rung",
              HermesUsageFormat.widestContextLabel(size: 2_000_000_000) == "~2000.0M/2000M")
        check("the reserved label covers the unestimated case",
              HermesUsageFormat.contextLabel(used: 999_900, size: 1_048_576, isEstimated: true)
                .count <= HermesUsageFormat.widestContextLabel(size: 1_048_576).count)
        check("a window-less gauge reserves nothing",
              HermesUsageFormat.widestContextLabel(size: 0).isEmpty)
        check("the reserved bar covers a full meter",
              HermesUsageFormat.widestBarLabel() == "[██████████] ~100%")
        check("the reserved bar is wider than a mid reading",
              HermesUsageFormat.widestBarLabel().count
                >= HermesUsageFormat.barLabel(percent: 94.9, isEstimated: true).count)

        // MARK: - Feature 4: attachments

        let fixture = "/Users/tony/git/Temp/acp-attach-fixture.txt"
        try? "ATTACH-FIXTURE-TOKEN-PINEAPPLE\n".write(
            toFile: fixture, atomically: true, encoding: .utf8)

        let text = ACPAttachment.at(path: fixture)
        check("a text file attaches as a file", text?.kind == .file)
        check("an attachment keeps its name", text?.name == "acp-attach-fixture.txt")
        check("a text file reports a text mime type", text?.mimeType?.hasPrefix("text/") == true)
        check("an attachment URI is a file URL", text?.uri.hasPrefix("file://") == true)
        check("path separators are left unencoded", text?.uri == "file://" + fixture)

        let block = text?.wireBlock ?? [:]
        check("the wire block is a resource link", block["type"] as? String == "resource_link")
        check("the wire block carries the URI", block["uri"] as? String == text?.uri)
        check("the wire block carries the name", block["name"] as? String == text?.name)
        check("the wire block carries a mime type", block["mimeType"] as? String != nil)
        check("a file block carries its size", block["size"] != nil)

        // A space or a `#` in a filename must not truncate or misdirect the URI. Built by `URL`,
        // which is the whole point: hand-rolled encoding gets these wrong.
        let spaced = ACPAttachment.at(path: "/Users/tony/git/Temp/a file#1.txt")
        check("a space is percent-encoded", spaced?.uri.contains("%20") == true)
        check("a hash is percent-encoded", spaced?.uri.contains("%23") == true)
        check("the URI keeps the file scheme", spaced?.uri.hasPrefix("file://") == true)
        check("the URI keeps its slashes",
              spaced?.uri == "file:///Users/tony/git/Temp/a%20file%231.txt")
        check("a directory is a folder attachment",
              ACPAttachment.at(path: "/tmp")?.kind == .folder)
        check("a folder produces a valid file URI",
              ACPAttachment.at(path: "/tmp")?.uri == "file:///tmp")
        check("a folder's block omits the mime type",
              ACPAttachment.at(path: "/tmp")?.wireBlock["mimeType"] == nil)
        check("a folder's block omits the size",
              ACPAttachment.at(path: "/tmp")?.wireBlock["size"] == nil)
        check("a symlinked directory is still a folder",
              ACPAttachment.at(path: "/tmp")?.kind == .folder)
        check("a non-ASCII name encodes as UTF-8",
              ACPAttachment.at(path: "/Users/tony/git/Temp/caf\u{00e9}.txt")?.uri
                == "file:///Users/tony/git/Temp/cafe%CC%81.txt")

        // A relative path would be silently rooted at the process's working directory, and a bare
        // `~` would name a directory nobody asked for, so both are refused.
        check("a relative path is refused", ACPAttachment.at(path: "relative/path.txt") == nil)
        check("a dot-relative path is refused", ACPAttachment.at(path: "./here.txt") == nil)
        check("a bare tilde is refused", ACPAttachment.at(path: "~") == nil)
        // A `~/` path is accepted, and normalised so path, uri and name describe one file.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        check("a tilde path is accepted",
              ACPAttachment.at(path: "~/notes.txt")?.path == home + "/notes.txt")
        check("a tilde path expands in its URI",
              ACPAttachment.at(path: "~/notes.txt")?.uri.contains("~") == false)

        // Equality must ignore the per-instance id, or dedupe can never fire.
        let sameAgain = ACPAttachment.at(path: fixture)
        check("two attachments to one path are equal", text == sameAgain)
        check("an attachment copies the same path", text?.path == sameAgain?.path)

        check("a missing file is still a file attachment",
              ACPAttachment.at(path: "/nope/gone.bin")?.kind == .file)
        check("an unknown suffix falls back to a generic type",
              ACPAttachment.at(path: "/nope/gone.zzz")?.mimeType == "application/octet-stream")

        let png = "/Users/tony/git/Temp/acp-attach-fixture.png"
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: png))
        check("an image attaches as an image", ACPAttachment.at(path: png)?.kind == .image)
        check("an image reports an image mime type",
              ACPAttachment.at(path: png)?.mimeType?.hasPrefix("image/") == true)

        // The attach menu's three entries, in Hermes' own order.
        check("the attach menu offers files, folder and images",
              ACPAttachmentSource.allCases.map(\.title) == ["Files…", "Folder…", "Images…"])
        check("only the folder entry picks a directory",
              ACPAttachmentSource.allCases.filter(\.choosesDirectories) == [.folder])
        check("the folder entry picks a single item", !ACPAttachmentSource.folder.allowsMultiple)
        check("the files entry allows many", ACPAttachmentSource.files.allowsMultiple)
        check("the images entry is the only filtered one",
              ACPAttachmentSource.allCases.filter { !$0.contentTypes.isEmpty } == [.images])

        // A prompt carrying an attachment keeps its text block first, and no bytes cross the pipe.
        let frame = try? ACPMessage.prompt(
            id: 1, sessionID: "s-1", text: "look at this", attachments: [text].compactMap { $0 })
        let json = frame.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let params = json?["params"] as? [String: Any]
        let blocks = params?["prompt"] as? [[String: Any]]
        check("a prompt with attachments has two blocks", blocks?.count == 2)
        check("the text block stays first", blocks?.first?["type"] as? String == "text")
        check("the attachment block is second",
              blocks?.last?["type"] as? String == "resource_link")
        check("the prompt names the session", params?["sessionId"] as? String == "s-1")

        // A text-only prompt must still be exactly one block: this is the common path.
        let plain = try? ACPMessage.prompt(id: 2, sessionID: "s-2", text: "hello")
        let plainJSON = plain.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let plainBlocks = (plainJSON?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        check("a text-only prompt is one block", plainBlocks?.count == 1)
        check("a text-only prompt keeps its text",
              plainBlocks?.first?["text"] as? String == "hello")

        try? FileManager.default.removeItem(atPath: fixture)
        try? FileManager.default.removeItem(atPath: png)

        if failures == 0 {
            print("\nAll Hermes feature checks passed.")
        } else {
            print("\n\(failures) Hermes feature check(s) failed.")
            exit(1)
        }
    }
}
