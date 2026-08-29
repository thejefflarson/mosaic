import Foundation
import Testing
@testable import Mosaic

/// The re-vendor gate (Docs/ADR/009): every manifest JSON that
/// `Scripts/update-herdr-manifests.sh` bundles must decode, every `regex`/
/// `line_regex` must compile under ICU `NSRegularExpression`, and every `region`
/// must be one herdr's engine-v3 evaluator actually understands. Mirrors
/// `Scripts/lib/validate_manifests.py`'s checks so a manifest that would fail
/// vendor-time validation also fails here, in CI, not in the field.
struct AgentManifestTests {
    // Decoded once and shared by every test below (a `Result`, not a bare
    // array, so a genuine decode failure still fails each test individually
    // with its real error — re-parsing the same ~20 bundled files per `@Test`
    // would otherwise be pure waste). `store` likewise compiles every regex
    // under ICU exactly once rather than once per test that needs it.
    private static let bundledManifestsResult: Result<[AgentManifest], Error> = Result {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "AgentManifests") ?? []
        let decoder = JSONDecoder()
        return try urls.map { try decoder.decode(AgentManifest.self, from: Data(contentsOf: $0)) }
    }
    private static let store = ManifestStore.loadBundled()

    private static func decodedBundledManifests() throws -> [AgentManifest] {
        let manifests = try bundledManifestsResult.get()
        try #require(!manifests.isEmpty)
        return manifests
    }

    private static func assertCompiles(_ gate: ManifestGate) throws {
        for pattern in gate.regex + gate.lineRegex {
            // Compile via CompiledRegex, not raw NSRegularExpression — the loader
            // normalizes Rust `\u{HHHH}` escapes to ICU `\x{HHHH}` before compiling
            // (see CompiledRegex.normalizedForICU / ADR-009 decision #5), so this must
            // assert the loader's compile path, not the raw manifest string.
            _ = try CompiledRegex(pattern: pattern)
        }
        for nested in gate.all + gate.any + gate.not {
            try assertCompiles(nested)
        }
    }

    @Test func everyBundledManifestDecodes() throws {
        let manifests = try Self.decodedBundledManifests()
        #expect(!manifests.isEmpty)
        for manifest in manifests {
            #expect(!manifest.id.isEmpty)
            #expect(!manifest.rules.isEmpty)
        }
    }

    @Test func everyRegexAndLineRegexCompilesUnderICU() throws {
        for manifest in try Self.decodedBundledManifests() {
            for rule in manifest.rules {
                try Self.assertCompiles(rule.gate)
            }
        }
    }

    @Test func everyRegionIsInTheEngineV3AllowSet() throws {
        // `Region` (AgentEngine.swift) is the single source of truth for the
        // engine-v3 region allow-set — this asserts every bundled rule's raw
        // `region` string actually parses there, rather than keeping a second,
        // independently-drifting copy of the name list in this test.
        for manifest in try Self.decodedBundledManifests() {
            for rule in manifest.rules {
                #expect(
                    Region(rule.region) != nil,
                    "\(manifest.id)/\(rule.id) has region \"\(rule.region)\" outside the engine-v3 set"
                )
            }
        }
    }

    @Test func everyManifestIsWithinEngineVersionOrProvablySkipped() throws {
        let store = Self.store
        for manifest in try Self.decodedBundledManifests() {
            let minEngineVersion = manifest.minEngineVersion ?? 1
            if minEngineVersion > manifestEngineVersion {
                #expect(
                    store.manifestsByID[manifest.id] == nil,
                    "\(manifest.id) declares min_engine_version \(minEngineVersion) > \(manifestEngineVersion) but was not skipped"
                )
            } else {
                #expect(
                    store.manifestsByID[manifest.id] != nil,
                    "\(manifest.id) declares min_engine_version \(minEngineVersion) <= \(manifestEngineVersion) but did not load"
                )
            }
        }
    }

    @Test func loadBundledToleratesAMissingResourceDirectory() {
        let store = ManifestStore.loadBundled(subdirectory: "NoSuchAgentManifestsDirectory")
        #expect(store.manifestsByID.isEmpty)
    }

    @Test func minimalRuleDecodesWithHerdrsTomllibDefaults() throws {
        // tomllib drops absent keys entirely; a rule with only id+state+contains
        // (herdr's smallest legal rule) must decode with the same defaults
        // tomllib would have applied: priority 0, region "whole_recent", empty
        // gate/matcher arrays, every visible_*/skip_state_update flag false.
        let json = #"{"id": "claude", "rules": [{"id": "r1", "state": "idle", "contains": ["foo"]}]}"#
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        let rule = try #require(manifest.rules.first)

        #expect(rule.state == .idle)
        #expect(rule.contains == ["foo"])
        #expect(rule.priority == 0)
        #expect(rule.region == "whole_recent")
        #expect(rule.visibleIdle == false)
        #expect(rule.visibleBlocker == false)
        #expect(rule.visibleWorking == false)
        #expect(rule.skipStateUpdate == false)
        #expect(rule.all.isEmpty)
        #expect(rule.any.isEmpty)
        #expect(rule.not.isEmpty)
        #expect(rule.regex.isEmpty)
        #expect(rule.lineRegex.isEmpty)
        #expect(manifest.version == nil)
        #expect(manifest.minEngineVersion == nil)
        #expect(manifest.aliases.isEmpty)
    }

    @Test func nestedGatesDecodeRecursively() throws {
        let json = #"""
        {"id": "x", "rules": [{"id": "r", "state": "blocked",
          "any": [{"contains": ["a"]}, {"all": [{"contains": ["b"]}, {"not": [{"contains": ["c"]}]}]}]}]}
        """#
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        let rule = try #require(manifest.rules.first)

        #expect(rule.any.count == 2)
        #expect(rule.any[1].all.count == 2)
        #expect(rule.any[1].all[1].not.first?.contains == ["c"])
    }

    @Test func compiledStoreCompilesRealManifestRegexes() throws {
        // A load-bearing sanity check on the actual bundled data, not just
        // synthetic JSON: claude.json alone carries braille/half-circle unicode
        // escapes (\x{2800}-\x{28FF}) and a multi-line MCP-task regex.
        let claude = try #require(Self.store.manifestsByID["claude"])
        #expect(!claude.rules.isEmpty)
    }
}
