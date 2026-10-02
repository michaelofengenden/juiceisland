import OpenIslandCore

/// Which `[features]` key turns Codex hooks on, from a `codex --version` line the app already has. Same rule as
/// upstream's private parser: 0.130 and later use `hooks`, older builds `codex_hooks`, unknown means `hooks`.
/// Upstream's own provider spawns `codex` with no environment and no timeout, so it is never used here.
enum CodexFeatureKey {
    static func from(versionLine: String?) -> CodexHooksFeatureFlagKey {
        guard let versionLine,
              let token = versionLine.split(whereSeparator: \.isWhitespace).first(where: { $0.first?.isNumber == true }) else {
            return .current
        }
        let parts = token.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return .current }
        return parts[0] > 0 || parts[1] >= 130 ? .current : .legacy
    }
}
