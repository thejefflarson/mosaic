import Foundation
import os

/// Structured log for the manifest loader. Auditable via Console.app (subsystem
/// filter: bundle ID, category: "manifests").
private let manifestLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.mosaic.CanvasTerm",
    category: "manifests"
)

/// The herdr detection-engine version Mosaic implements (Docs/ADR/009). A bundled
/// manifest whose `minEngineVersion` exceeds this is skipped wholesale at load —
/// never partially evaluated — and that agent falls back to the generic,
/// output-idle detection tier (ADR-007).
let manifestEngineVersion = 3

// MARK: - Codable model
//
// Mirrors herdr's `src/detect/manifest.rs` schema 1:1 (Docs/ADR/009). Decoded
// from the vendored, TOML→JSON-converted files under
// `Mosaic/Resources/AgentManifests/` (`Scripts/update-herdr-manifests.sh`); the
// JSON key names are herdr's own TOML keys (snake_case), hence the explicit
// `CodingKeys` below. `tomllib` drops absent keys at vendor time, so every
// optional/defaulted field here must decode when its key is simply missing —
// `JSONDecoder` does not synthesize Swift's default-parameter values for a
// missing key, so each of those fields gets a custom `init(from:)`.

private extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `defaultValue` when the key is absent —
    /// herdr's `tomllib` drops a field entirely when it equals the schema
    /// default, so a missing key must decode as that default, not fail.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? defaultValue
    }
}

/// One agent's detection manifest.
struct AgentManifest: Codable, Sendable {
    let id: String
    let version: String?
    let minEngineVersion: Int?
    let updatedAt: String?
    let aliases: [String]
    let rules: [ManifestRule]

    private enum CodingKeys: String, CodingKey {
        case id, version, aliases, rules
        case minEngineVersion = "min_engine_version"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        version: String? = nil,
        minEngineVersion: Int? = nil,
        updatedAt: String? = nil,
        aliases: [String] = [],
        rules: [ManifestRule]
    ) {
        self.id = id
        self.version = version
        self.minEngineVersion = minEngineVersion
        self.updatedAt = updatedAt
        self.aliases = aliases
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        minEngineVersion = try container.decodeIfPresent(Int.self, forKey: .minEngineVersion)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        aliases = try container.decode([String].self, forKey: .aliases, default: [])
        rules = try container.decode([ManifestRule].self, forKey: .rules)
    }
}

/// 1:1 with `AgentActivity` (`AgentActivityDetector.swift`) — herdr's engine has
/// exactly these four states. `nil` on a rule means "bookkeeping only" (e.g. a
/// `skipStateUpdate` rule that recognizes a transient overlay without asserting a
/// state).
enum ManifestState: String, Codable, Sendable {
    case idle, working, blocked, unknown
}

/// A boolean gate over herdr's matcher primitives: `contains` (substring,
/// case-insensitive), `regex`/`lineRegex` (compiled as ICU `NSRegularExpression`
/// at load — see `CompiledGate`), and the boolean combinators `all`/`any`/`not`,
/// each an array of further nested gates (herdr caps nesting depth and matcher
/// counts at vendor time — `Scripts/lib/validate_manifests.py`).
struct ManifestGate: Codable, Sendable {
    let all: [ManifestGate]
    let any: [ManifestGate]
    let not: [ManifestGate]
    let contains: [String]
    let regex: [String]
    let lineRegex: [String]

    private enum CodingKeys: String, CodingKey {
        case all, any, not, contains, regex
        case lineRegex = "line_regex"
    }

    init(
        all: [ManifestGate] = [],
        any: [ManifestGate] = [],
        not: [ManifestGate] = [],
        contains: [String] = [],
        regex: [String] = [],
        lineRegex: [String] = []
    ) {
        self.all = all
        self.any = any
        self.not = not
        self.contains = contains
        self.regex = regex
        self.lineRegex = lineRegex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        all = try container.decode([ManifestGate].self, forKey: .all, default: [])
        any = try container.decode([ManifestGate].self, forKey: .any, default: [])
        not = try container.decode([ManifestGate].self, forKey: .not, default: [])
        contains = try container.decode([String].self, forKey: .contains, default: [])
        regex = try container.decode([String].self, forKey: .regex, default: [])
        lineRegex = try container.decode([String].self, forKey: .lineRegex, default: [])
    }
}

/// One detection rule within a manifest: scored by `priority`, matched against
/// `region` of the terminal's visible text, and — like a nested `ManifestGate` —
/// carrying its own matcher fields (a rule *is* its own top-level gate, stored as
/// `gate` and exposed as flat `all`/`any`/`not`/`contains`/`regex`/`lineRegex`
/// properties so callers don't need to know that). Defaults mirror herdr's
/// `tomllib` decode defaults exactly: `priority` 0, `region` `"whole_recent"`,
/// empty gate/matcher arrays, `false` for every `visible_*`/`skipStateUpdate`
/// flag.
struct ManifestRule: Codable, Sendable {
    let id: String
    let state: ManifestState?
    let priority: Int
    let region: String
    let visibleIdle: Bool
    let visibleBlocker: Bool
    let visibleWorking: Bool
    let skipStateUpdate: Bool
    let gate: ManifestGate

    var all: [ManifestGate] { gate.all }
    var any: [ManifestGate] { gate.any }
    var not: [ManifestGate] { gate.not }
    var contains: [String] { gate.contains }
    var regex: [String] { gate.regex }
    var lineRegex: [String] { gate.lineRegex }

    private enum CodingKeys: String, CodingKey {
        case id, state, priority, region
        case visibleIdle = "visible_idle"
        case visibleBlocker = "visible_blocker"
        case visibleWorking = "visible_working"
        case skipStateUpdate = "skip_state_update"
    }

    init(
        id: String,
        state: ManifestState? = nil,
        priority: Int = 0,
        region: String = "whole_recent",
        visibleIdle: Bool = false,
        visibleBlocker: Bool = false,
        visibleWorking: Bool = false,
        skipStateUpdate: Bool = false,
        gate: ManifestGate = ManifestGate()
    ) {
        self.id = id
        self.state = state
        self.priority = priority
        self.region = region
        self.visibleIdle = visibleIdle
        self.visibleBlocker = visibleBlocker
        self.visibleWorking = visibleWorking
        self.skipStateUpdate = skipStateUpdate
        self.gate = gate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        state = try container.decodeIfPresent(ManifestState.self, forKey: .state)
        priority = try container.decode(Int.self, forKey: .priority, default: 0)
        region = try container.decode(String.self, forKey: .region, default: "whole_recent")
        visibleIdle = try container.decode(Bool.self, forKey: .visibleIdle, default: false)
        visibleBlocker = try container.decode(Bool.self, forKey: .visibleBlocker, default: false)
        visibleWorking = try container.decode(Bool.self, forKey: .visibleWorking, default: false)
        skipStateUpdate = try container.decode(Bool.self, forKey: .skipStateUpdate, default: false)
        // A rule's matcher fields (all/any/not/contains/regex/line_regex) sit
        // flat in the same JSON object as id/state/priority/region — decode them
        // via ManifestGate's own decoder rather than re-implementing its
        // decode-with-defaults logic here. Decoding two independent keyed
        // containers off the same `decoder` is standard Codable composition; it
        // does not consume/advance anything, so this can't collide with the
        // container above.
        gate = try ManifestGate(from: decoder)
    }
}

// MARK: - Compiled store
//
// The evaluator (JEF-902) needs compiled `NSRegularExpression`s, not pattern
// strings — compiling per-evaluation would recompile the same handful of ICU
// patterns on every ~1 Hz drive tick, for no benefit, since the patterns are
// fixed at load. `ManifestStore` decodes and compiles every bundled manifest
// exactly once at startup.

/// A compiled `NSRegularExpression`, boxed so it can be stored inside the
/// otherwise-`Sendable` compiled manifest tree. Apple documents
/// `NSRegularExpression` instances as immutable and safe to use concurrently
/// from multiple threads, but Foundation does not (as of this SDK) declare the
/// class `Sendable` itself — this wrapper asserts that guarantee once, here,
/// rather than scattering `@unchecked Sendable` across call sites.
struct CompiledRegex: @unchecked Sendable {
    let expression: NSRegularExpression

    /// The source pattern, as compiled — `NSRegularExpression` already retains it.
    var pattern: String { expression.pattern }

    init(pattern: String) throws {
        expression = try NSRegularExpression(pattern: pattern)
    }
}

/// `ManifestGate`, with `regex`/`lineRegex` compiled.
struct CompiledGate: Sendable {
    let all: [CompiledGate]
    let any: [CompiledGate]
    let not: [CompiledGate]
    let contains: [String]
    let regex: [CompiledRegex]
    let lineRegex: [CompiledRegex]

    init(_ gate: ManifestGate) throws {
        all = try gate.all.map(CompiledGate.init)
        any = try gate.any.map(CompiledGate.init)
        not = try gate.not.map(CompiledGate.init)
        contains = gate.contains
        regex = try gate.regex.map(CompiledRegex.init)
        lineRegex = try gate.lineRegex.map(CompiledRegex.init)
    }
}

/// `ManifestRule`, with its matcher fields compiled into a `CompiledGate`.
struct CompiledRule: Sendable {
    let id: String
    let state: ManifestState?
    let priority: Int
    let region: String
    let visibleIdle: Bool
    let visibleBlocker: Bool
    let visibleWorking: Bool
    let skipStateUpdate: Bool
    let gate: CompiledGate

    init(_ rule: ManifestRule) throws {
        id = rule.id
        state = rule.state
        priority = rule.priority
        region = rule.region
        visibleIdle = rule.visibleIdle
        visibleBlocker = rule.visibleBlocker
        visibleWorking = rule.visibleWorking
        skipStateUpdate = rule.skipStateUpdate
        gate = try CompiledGate(rule.gate)
    }
}

/// `AgentManifest`, with every rule compiled.
struct CompiledManifest: Sendable {
    let id: String
    let version: String?
    let aliases: [String]
    let rules: [CompiledRule]

    init(_ manifest: AgentManifest) throws {
        id = manifest.id
        version = manifest.version
        aliases = manifest.aliases
        rules = try manifest.rules.map(CompiledRule.init)
    }
}

/// Every bundled agent-detection manifest, decoded and regex-compiled once at
/// startup. Immutable and `Sendable` — safe to build off the main actor (no PTY,
/// no UI dependency) and to share across every terminal's detection. Wiring this
/// into `driveAgentActivity` is JEF-902; this type only loads and compiles.
struct ManifestStore: Sendable {
    /// Compiled manifests keyed by `id` (herdr's stable per-agent identifier;
    /// matched against a terminal's foreground process later, in JEF-902).
    let manifestsByID: [String: CompiledManifest]

    /// Loads and compiles every `*.json` resource under `subdirectory` in
    /// `bundle`. Pure aside from the resource reads; safe to call off the main
    /// actor. A manifest that fails to decode, fails to compile (a pattern that
    /// doesn't survive TOML→JSON→ICU should never happen post-vendor-validation,
    /// but the loader must not trust that blindly), or declares
    /// `minEngineVersion` above `manifestEngineVersion` is skipped and logged —
    /// never partially loaded — so one broken or future-engine manifest can't
    /// crash startup or silently half-match. That agent's terminals fall back to
    /// the generic detection tier (ADR-007).
    static func loadBundled(bundle: Bundle = .main, subdirectory: String = "AgentManifests") -> ManifestStore {
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) else {
            manifestLog.error("no \(subdirectory, privacy: .public) resources found in bundle")
            return ManifestStore(manifestsByID: [:])
        }

        let decoder = JSONDecoder()
        var manifestsByID: [String: CompiledManifest] = [:]
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let manifest = try decoder.decode(AgentManifest.self, from: data)
                // Absent min_engine_version means the manifest declares no floor —
                // treat it as engine 1, which always passes this check.
                let minEngineVersion = manifest.minEngineVersion ?? 1
                guard minEngineVersion <= manifestEngineVersion else {
                    manifestLog.notice(
                        "skipping manifest \(manifest.id, privacy: .public): min_engine_version \(minEngineVersion, privacy: .public) exceeds implemented engine \(manifestEngineVersion, privacy: .public)"
                    )
                    continue
                }
                manifestsByID[manifest.id] = try CompiledManifest(manifest)
            } catch {
                manifestLog.error(
                    "skipping manifest at \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return ManifestStore(manifestsByID: manifestsByID)
    }
}
