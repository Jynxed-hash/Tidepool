import Foundation

/// On-disk evidence that a tool is installed. Every path here is one we
/// could cite. Tools with no documented install marker are catalog entries
/// without a signature, so they are never reported as detected.
public struct InstallSignature: Sendable, Equatable {
    public var id: String
    public var applicationNames: [String]
    public var executableNames: [String]
    public var homeRelativePaths: [String]
    /// Environment variables whose value is a directory when the tool is present.
    public var environmentDirectoryVariables: [String]

    public init(
        id: String,
        applicationNames: [String] = [],
        executableNames: [String] = [],
        homeRelativePaths: [String] = [],
        environmentDirectoryVariables: [String] = []
    ) {
        self.id = id
        self.applicationNames = applicationNames
        self.executableNames = executableNames
        self.homeRelativePaths = homeRelativePaths
        self.environmentDirectoryVariables = environmentDirectoryVariables
    }
}

public enum CatalogState: String, Sendable, Equatable {
    /// Provider is implemented and evidence of an install was found.
    case active
    /// Install evidence exists. No provider reads it yet.
    case comingSoon
    /// A signature exists and nothing matched.
    case notDetected
    /// We do not know a trustworthy on-disk marker, so we do not guess.
    case undetectable
}

public struct CatalogEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var implemented: Bool
    public var signature: InstallSignature?
    /// Shown when `signature` is nil.
    public var undetectableReason: String?

    public init(
        id: String,
        displayName: String,
        implemented: Bool,
        signature: InstallSignature?,
        undetectableReason: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.implemented = implemented
        self.signature = signature
        self.undetectableReason = undetectableReason
    }
}

public struct CatalogStatus: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var state: CatalogState
    public var evidence: [String]
    public var note: String?

    public init(id: String, displayName: String, state: CatalogState, evidence: [String], note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.evidence = evidence
        self.note = note
    }
}

public enum ToolCatalog {
    public static let claudeCode = "claude-code"
    public static let cursor = "cursor"
    public static let codex = "codex"
    public static let grokBot = "grok-bot"
    public static let wisprFlow = "wispr-flow"

    public static let v1: [CatalogEntry] = [
        CatalogEntry(
            id: claudeCode,
            displayName: "Claude Code",
            implemented: true,
            signature: InstallSignature(
                id: claudeCode,
                executableNames: ["claude"],
                homeRelativePaths: [".claude"]
            )
        ),
        CatalogEntry(
            id: cursor,
            displayName: "Cursor",
            implemented: false,
            signature: InstallSignature(
                id: cursor,
                applicationNames: ["Cursor.app"],
                executableNames: ["cursor"],
                homeRelativePaths: ["Library/Application Support/Cursor"]
            )
        ),
        CatalogEntry(
            id: codex,
            displayName: "Codex",
            implemented: false,
            signature: InstallSignature(
                id: codex,
                executableNames: ["codex"],
                homeRelativePaths: [".codex"],
                environmentDirectoryVariables: ["CODEX_HOME"]
            )
        ),
        CatalogEntry(
            id: grokBot,
            displayName: "Grok Bot",
            implemented: false,
            signature: nil,
            undetectableReason: "No documented on-disk marker yet"
        ),
        CatalogEntry(
            id: wisprFlow,
            displayName: "Wispr Flow",
            implemented: false,
            signature: InstallSignature(
                id: wisprFlow,
                applicationNames: ["Wispr Flow.app"]
            )
        ),
    ]
}

public struct DetectionInput: Sendable, Equatable {
    public var applicationNames: [String]
    public var executableNames: [String]
    public var existingHomeRelativePaths: [String]
    /// Absolute directories that exist, keyed by the environment variable that named them.
    public var existingEnvironmentDirectories: [String: String]

    public init(
        applicationNames: [String] = [],
        executableNames: [String] = [],
        existingHomeRelativePaths: [String] = [],
        existingEnvironmentDirectories: [String: String] = [:]
    ) {
        self.applicationNames = applicationNames
        self.executableNames = executableNames
        self.existingHomeRelativePaths = existingHomeRelativePaths
        self.existingEnvironmentDirectories = existingEnvironmentDirectories
    }
}

public enum ToolDetector {
    public static func status(for input: DetectionInput, catalog: [CatalogEntry] = ToolCatalog.v1) -> [CatalogStatus] {
        catalog.map { entry in
            let evidence = evidence(for: entry.signature, in: input)
            let state: CatalogState
            if entry.signature == nil {
                state = .undetectable
            } else if evidence.isEmpty {
                state = .notDetected
            } else if entry.implemented {
                state = .active
            } else {
                state = .comingSoon
            }
            return CatalogStatus(
                id: entry.id,
                displayName: entry.displayName,
                state: state,
                evidence: evidence,
                note: entry.undetectableReason
            )
        }
    }

    public static func evidence(for signature: InstallSignature?, in input: DetectionInput) -> [String] {
        guard let signature else { return [] }
        var found: [String] = []
        let apps = Set(input.applicationNames)
        for name in signature.applicationNames where apps.contains(name) {
            found.append(name)
        }
        let bins = Set(input.executableNames)
        for name in signature.executableNames where bins.contains(name) {
            found.append(name)
        }
        let homes = Set(input.existingHomeRelativePaths)
        for path in signature.homeRelativePaths where homes.contains(path) {
            found.append(path)
        }
        for variable in signature.environmentDirectoryVariables {
            if let path = input.existingEnvironmentDirectories[variable] {
                found.append("\(variable)=\(path)")
            }
        }
        return found
    }

    /// Walks real directories. Tests pass their own roots.
    public static func probe(
        home: URL,
        applicationDirectories: [URL],
        path: String,
        environment: [String: String],
        catalog: [CatalogEntry] = ToolCatalog.v1,
        fileManager: FileManager = .default
    ) -> DetectionInput {
        let signatures = catalog.compactMap(\.signature)
        var applications: [String] = []
        for directory in applicationDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            applications.append(contentsOf: names)
        }

        let wantedBins = Set(signatures.flatMap(\.executableNames))
        var foundBins: [String] = []
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let dir = String(directory)
            for name in wantedBins {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    foundBins.append(name)
                }
            }
        }

        let wantedHomes = Set(signatures.flatMap(\.homeRelativePaths))
        var foundHomes: [String] = []
        for relative in wantedHomes {
            let url = home.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                foundHomes.append(relative)
            }
        }

        var envDirs: [String: String] = [:]
        let wantedEnv = Set(signatures.flatMap(\.environmentDirectoryVariables))
        for variable in wantedEnv {
            guard let value = environment[variable], !value.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
                envDirs[variable] = value
            }
        }

        return DetectionInput(
            applicationNames: applications,
            executableNames: foundBins,
            existingHomeRelativePaths: foundHomes,
            existingEnvironmentDirectories: envDirs
        )
    }
}
