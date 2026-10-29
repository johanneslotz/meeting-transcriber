import Foundation

/// Resolution of the Live Minutes endpoint, model and key from the stored
/// settings. Empty Live Minutes fields fall back to the protocol provider's
/// OpenAI-compatible settings, so a user with a local LLM configured for
/// protocols gets Live Minutes without configuring anything twice.
extension AppSettings {
    var liveMinutesResolvedEndpoint: String {
        let own = liveMinutesEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? openAIEndpoint : own
    }

    var liveMinutesResolvedModel: String {
        let own = liveMinutesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? openAIModel : own
    }

    /// True when the summary goes to the same endpoint the protocol provider uses.
    var liveMinutesUsesProtocolEndpoint: Bool {
        liveMinutesResolvedEndpoint == openAIEndpoint
    }

    /// The protocol provider's API key, sent only when the summary goes to that
    /// provider's own endpoint. A separately configured endpoint never receives
    /// a key that was entered for a different one.
    var liveMinutesAPIKey: String? {
        guard liveMinutesUsesProtocolEndpoint, !openAIAPIKey.isEmpty else { return nil }
        return openAIAPIKey
    }

    /// False when meeting text would leave this Mac.
    var liveMinutesEndpointIsLocal: Bool {
        LiveMinutesEndpointPolicy.isLocal(liveMinutesResolvedEndpoint)
    }
}

/// Whether an endpoint URL points at this machine. Anything that does not
/// parse counts as not local, so the Settings warning errs toward showing.
enum LiveMinutesEndpointPolicy {
    static func isLocal(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
