import Matching
import Primitives

public extension Sensitivity {
    /// Which findings become handles, and of what tier.
    struct ShieldPolicy: Sendable {
        public var presets: [Preset]
        /// Findings scoring this or more become handles.
        public var handleAt: Int
        /// Findings scoring this or more, below `handleAt`, become soft
        /// handles; lower ones are flagged and left.
        public var softAt: Int
        /// A tier per kind instead of by score, for kinds a workflow needs
        /// freely (private addresses in development work).
        public var tiers: [Kind: Tier]
        /// Values never replaced, such as the business's public phone
        /// number; compared ignoring case.
        public var never: Set<String>

        public init(
            presets: [Preset] = Preset.all,
            handleAt: Int = 80,
            softAt: Int = 60,
            tiers: [Kind: Tier] = [.network: .soft, .identifier: .soft],
            never: Set<String> = []
        ) {
            self.presets = presets
            self.handleAt = handleAt
            self.softAt = softAt
            self.tiers = tiers
            self.never = Set(never.map { $0.lowercased() })
        }

        public static let standard = Self()

        /// The tier of `finding`; flagged findings stay in the text.
        public func tier(for finding: Finding) -> Tier {
            let byScore: Tier = finding.score.raw >= handleAt ? .handle : finding.score.raw >= softAt ? .soft : .flag
            guard byScore != .flag, let tier = tiers[finding.kind] else { return byScore }
            return tier
        }
    }

    /// What protecting a payload did: one item per finding, values masked.
    struct Protection: Sendable, Codable, Hashable {
        public struct Item: Sendable, Codable, Hashable {
            /// The field path in a JSON payload (`payments[0].iban`), or
            /// empty for plain text.
            public let path: String
            public let tier: Tier
            public let kind: Kind
            /// Nil for flagged findings, which keep their text.
            public let handle: Handle?
            public let preview: String
            public let detector: String
            public let reason: String
            public let score: Int
        }

        public var items: [Item]

        public init(items: [Item] = []) {
            self.items = items
        }

        public var counts: [Kind: Int] {
            items.filter { $0.handle != nil }.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
        }
    }

    /// Why a handle could not be given to a tool.
    enum ShieldFailure: Error, Sendable, Hashable, CustomStringConvertible {
        /// Stale or untraceable: not in the vault (expired, released, or from
        /// another machine). Fetch the value from its source again.
        case unknown(Handle)
        /// The tool may not use it without the owner's grant.
        case notPermitted(Handle, tool: String)

        public var description: String {
            switch self {
            case .unknown(let handle):
                return "\(handle.token) is stale or untraceable: the vault no longer holds its value (expired, released, or recorded on another machine). Read the value again from its source."
            case .notPermitted(let handle, let tool):
                return "\(tool) may not use \(handle.token); ask the owner to grant it, or use a tool of the domain it came from."
            }
        }
    }

    /// Replaces sensitive data with handles on the way out of a tool and
    /// puts the values back on the way in, through one vault.
    struct Shield: Sendable {
        public let vault: Vault
        public let policy: ShieldPolicy
        /// The session whose payloads pass, recorded on each entry.
        public let session: String?

        public init(vault: Vault, policy: ShieldPolicy = .standard, session: String? = nil) {
            self.vault = vault
            self.policy = policy
            self.session = session
        }

        /// `text` with handles for what the presets and the vault's known
        /// values find; `source` names where it came from (tool and path).
        public func protect(_ text: String, source: String, path: String = "") async -> (text: String, protection: Protection) {
            var detectors = policy.presets.flatMap(\.detectors)
            detectors.append(await vault.knownValues())
            let findings = Sensitivity.scan(text, detectors: detectors).filter { finding in
                !policy.never.contains(finding.text.lowercased())
                    && Handle.occurrences(in: finding.text).isEmpty
            }
            guard !findings.isEmpty else { return (text, Protection()) }

            var items: [Protection.Item] = []
            var standIns: [String?] = []
            for finding in findings {
                let tier = policy.tier(for: finding)
                var handle: Handle?
                if tier != .flag {
                    handle = await vault.handle(
                        for: finding.text,
                        kind: finding.kind,
                        tier: tier,
                        detector: finding.detector,
                        reason: finding.reason,
                        score: finding.score.raw,
                        source: path.isEmpty ? source : "\(source) \(path)",
                        session: session
                    )
                }
                standIns.append(handle?.token)
                items.append(.init(
                    path: path,
                    tier: tier,
                    kind: finding.kind,
                    handle: handle,
                    preview: Sensitivity.mask(finding.text),
                    detector: finding.detector,
                    reason: finding.reason,
                    score: finding.score.raw
                ))
            }
            let replaced = Sensitivity.replacing(findings, in: text) { index, _ in standIns[index] }
            return (replaced, Protection(items: items))
        }

        /// Every string in `value` protected; object keys stay as they are.
        public func protect(_ value: JSONValue, source: String) async -> (value: JSONValue, protection: Protection) {
            var protection = Protection()
            let protected = await protect(value, source: source, path: "", into: &protection)
            return (protected, protection)
        }

        private func protect(_ value: JSONValue, source: String, path: String, into protection: inout Protection) async -> JSONValue {
            switch value {
            case .string(let text):
                let (protected, found) = await protect(text, source: source, path: path)
                protection.items += found.items
                return .string(protected)
            case .array(let values):
                var result: [JSONValue] = []
                for (index, element) in values.enumerated() {
                    result.append(await protect(element, source: source, path: "\(path)[\(index)]", into: &protection))
                }
                return .array(result)
            case .object(let members):
                var result: [String: JSONValue] = [:]
                for key in members.keys.sorted() {
                    result[key] = await protect(members[key]!, source: source, path: path.isEmpty ? key : "\(path).\(key)", into: &protection)
                }
                return .object(result)
            default:
                return value
            }
        }

        /// `text` with each handle replaced by its value when `permits`
        /// allows it; throws for the first unknown or refused handle.
        public func resolve(
            _ text: String,
            for tool: String,
            permits: (HandleDescription) -> Bool
        ) async throws(ShieldFailure) -> String {
            let occurrences = Handle.occurrences(in: text)
            guard !occurrences.isEmpty else { return text }
            var values: [String] = []
            for (handle, _) in occurrences {
                guard let description = await vault.describe(handle), let value = await vault.value(of: handle) else {
                    throw .unknown(handle)
                }
                guard permits(description) else {
                    throw .notPermitted(handle, tool: tool)
                }
                values.append(value)
            }
            var output = ""
            var index = text.startIndex
            var offset = 0
            for (position, occurrence) in occurrences.enumerated() {
                let start = text.index(index, offsetBy: occurrence.range.startOffset - offset)
                let end = text.index(start, offsetBy: occurrence.range.offsetRange.count)
                output += text[index..<start]
                output += values[position]
                index = end
                offset = occurrence.range.endOffset
            }
            output += text[index...]
            return output
        }

        /// Every string in `value` resolved, as `resolve(_:for:permits:)`.
        public func resolve(
            _ value: JSONValue,
            for tool: String,
            permits: (HandleDescription) -> Bool
        ) async throws(ShieldFailure) -> JSONValue {
            switch value {
            case .string(let text):
                return .string(try await resolve(text, for: tool, permits: permits))
            case .array(let values):
                var result: [JSONValue] = []
                for element in values {
                    result.append(try await resolve(element, for: tool, permits: permits))
                }
                return .array(result)
            case .object(let members):
                var result: [String: JSONValue] = [:]
                for (key, member) in members {
                    result[key] = try await resolve(member, for: tool, permits: permits)
                }
                return .object(result)
            default:
                return value
            }
        }
    }

    /// `text` with each finding replaced by what `standIn` returns for it
    /// (nil keeps the text). Findings must not overlap.
    static func replacing(_ findings: [Finding], in text: String, standIn: (Int, Finding) -> String?) -> String {
        var output = ""
        var index = text.startIndex
        var offset = 0
        for (position, finding) in findings.enumerated().sorted(by: { $0.element.range.startOffset < $1.element.range.startOffset }) {
            let start = text.index(index, offsetBy: finding.range.startOffset - offset)
            let end = text.index(start, offsetBy: finding.range.offsetRange.count)
            output += text[index..<start]
            output += standIn(position, finding) ?? String(text[start..<end])
            index = end
            offset = finding.range.endOffset
        }
        output += text[index...]
        return output
    }
}
