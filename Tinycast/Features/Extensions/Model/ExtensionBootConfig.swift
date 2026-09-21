import Foundation

/// Machine facts the Node shims answer from without a host call. Sent once, when the engine boots.
struct ExtensionBootConfig: Sendable {
    var arch: String
    var release: String
    var hostname: String
    var username: String
    var shell: String
    var homeDirectory: String
    var temporaryDirectory: String
    var workingDirectory: String
    var totalMemory: Double
    var environmentVariables: [String: String]

    static func current(supportDirectory: URL) -> ExtensionBootConfig {
        let info = ProcessInfo.processInfo
        var arch = "arm64"
        #if arch(x86_64)
            arch = "x64"
        #endif
        // A GUI app inherits a bare environment; extensions shelling out expect a login-ish PATH.
        //
        // The inherited PATH cannot be trusted as a base: a macOS GUI process can carry a
        // truncated one (observed ending mid-string at "/Applications/Little"), and appending
        // the Homebrew directories to that still leaves binaries like `deno` unreachable —
        // which breaks yt-dlp's JS challenge solving and any other tool an extension shells
        // out to. So the required directories are stated absolutely and the inherited entries
        // are only kept as extras, de-duplicated, with the required ones first.
        var variables = info.environment
        let requiredPathEntries = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let inheritedPathEntries = (variables["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var seen = Set<String>()
        variables["PATH"] = (requiredPathEntries + inheritedPathEntries)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        variables["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path

        return ExtensionBootConfig(
            arch: arch,
            release: info.operatingSystemVersionString,
            hostname: info.hostName,
            username: NSUserName(),
            shell: info.environment["SHELL"] ?? "/bin/zsh",
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            temporaryDirectory: FileManager.default.temporaryDirectory.path,
            workingDirectory: supportDirectory.path,
            totalMemory: Double(info.physicalMemory),
            environmentVariables: variables)
    }

    func jsonString() -> String {
        ExtensionRuntime.jsonString(
            from: [
                "node": [
                    "arch": arch,
                    "release": release,
                    "hostname": hostname,
                    "username": username,
                    "shell": shell,
                    "homedir": homeDirectory,
                    "tmpdir": temporaryDirectory,
                    "cwd": workingDirectory,
                    "totalmem": totalMemory,
                    "env": environmentVariables,
                    "execPath": ""
                ]
            ])
    }
}

/// Everything one command needs at mount: environment, preferences, caches, arguments.
struct ExtensionLaunchContext: Sendable {
    var extensionName: String
    var extensionTitle: String
    var commandName: String
    var commandMode: ExtensionCommandMode
    var assetsPath: String
    var supportPath: String
    var preferences: [String: ExtensionPreferenceValue]
    var caches: [String: [String: String]]
    var arguments: [String: String]
    var fallbackText: String?
    var launchType: ExtensionLaunchType = .userInitiated
    /// Injected, never read: a running command keeps what it booted with.
    var isDarkAppearance: Bool

    func jsonString() -> String {
        var environment: [String: Any] = [
            "extensionName": extensionName,
            "commandName": commandName,
            "commandMode": commandMode.rawValue,
            "assetsPath": assetsPath,
            "supportPath": supportPath,
            "isDevelopment": false,
            // Extensions gate features on this; report the API level the shim implements.
            "raycastVersion": ExtensionRuntimeVersion.raycastAPI,
            "textSize": "medium",
            "appearance": isDarkAppearance ? "dark" : "light",
            "launchType": launchType.rawValue,
            "canAccess": false
        ]
        environment["ownerOrAuthorName"] = extensionTitle

        var launchProps: [String: Any] = ["launchType": launchType.rawValue, "arguments": arguments]
        if let fallbackText { launchProps["fallbackText"] = fallbackText }

        return ExtensionRuntime.jsonString(
            from: [
                "environment": environment,
                "preferences": preferences.mapValues(\.jsonValue),
                "caches": caches,
                "launchProps": launchProps
            ])
    }
}

enum ExtensionRuntimeVersion {
    /// The @raycast/api version the bundled shim tracks. Surfaced as `environment.raycastVersion`.
    static let raycastAPI = "2.0.3"
}
