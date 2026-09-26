import Foundation

/// A released version: `MAJOR.MINOR.PATCH`, optionally `-beta.N` or the fork's `-tN.M` marker,
/// ordered by semver precedence.
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Nil on a stable release, which outranks every prerelease of the same triple.
    let beta: Int?
    /// The fork's own revision marker, e.g. `t0.1` in `0.11.3-t0.1`.
    ///
    /// This fork never publishes an update stream — `ReleaseChannel` answers `.development` for its
    /// bundle id — so the marker exists to be *displayed*, and ordering only needs to be sane rather
    /// than meaningful. It is deliberately not a prerelease: `ReleaseFeed` rejects a tag whose
    /// prerelease flag disagrees with its version, and a fork build is not a prerelease.
    let fork: String?

    init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Release tags carry a leading `v`; `CFBundleShortVersionString` never does.
        if body.first == "v" { body = body.dropFirst() }

        let halves = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
            let major = Self.number(numbers[0]),
            let minor = Self.number(numbers[1]),
            let patch = Self.number(numbers[2])
        else { return nil }

        var beta: Int?
        var fork: String?
        if halves.count == 2 {
            let suffix = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            if suffix.count == 2, suffix[0] == "beta", let count = Self.number(suffix[1]) {
                beta = count
            } else if suffix.count == 2, let forkText = Self.forkMarker(suffix[0], suffix[1]) {
                fork = forkText
            } else {
                // `beta` is the only prerelease channel that ships; anything else is unreadable.
                return nil
            }
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
        self.fork = fork
    }

    var isPrerelease: Bool { beta != nil }

    /// Whether this is a build of the fork rather than a stock release.
    var isFork: Bool { fork != nil }

    var description: String {
        let triple = "\(major).\(minor).\(patch)"
        if let beta { return "\(triple)-beta.\(beta)" }
        if let fork { return "\(triple)-\(fork)" }
        return triple
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.beta, rhs.beta) {
        case (nil, nil):
            // A local revision sits above the stock build it was cut from, and below anything else.
            return lhs.fork == nil && rhs.fork != nil
        // A prerelease leads to its release, so it sorts below one and never above it.
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let left), .some(let right)): return left < right
        }
    }

    /// `t0` + `1` → `t0.1`; nil when the leading field is not the fork's own `tN` marker.
    private static func forkMarker(_ head: Substring, _ tail: Substring) -> String? {
        guard head.count > 1, head.first == "t" else { return nil }
        let digits = head.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            let count = number(tail)
        else { return nil }
        return "t\(digits).\(count)"
    }

    /// Rejects a signed or padded field, which `Int` would silently reinterpret.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}

extension AppVersion: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = AppVersion(text) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "Not a version: \(text)")
        }
        self = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
