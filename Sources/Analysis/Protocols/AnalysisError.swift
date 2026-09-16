import Foundation

/// Every failure the analysis layer reports. Underlying framework errors are carried as text so
/// the error stays Equatable and Codable-friendly for logs and reports.
public enum AnalysisError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file does not exist.
    case fileNotFound(URL)
    /// The file exists but the framework could not open it as audio.
    case unsupportedAsset(URL, reason: String)
    /// The asset is DRM-protected and cannot be analysed.
    case protectedContent(URL)
    /// Analysis ran and failed.
    case analysisFailed(URL, capabilities: Set<AnalysisCapability>, reason: String)
    /// The provider does not offer these capabilities.
    case unsupportedCapabilities(Set<AnalysisCapability>, provider: String)
    /// Analysis completed without the requested result (the framework returned nil for it).
    case missingResult(AnalysisCapability, provider: String)
    /// No provider is registered or selected for the capability.
    case providerUnavailable(AnalysisCapability, name: String?)
    /// The selected provider does not conform to the protocol the capability needs.
    case providerMismatch(AnalysisCapability, name: String)
    /// A provider name was not found in the registry for that capability.
    case unknownProvider(name: String, capability: AnalysisCapability)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "file not found: \(url.path)"
        case .unsupportedAsset(let url, let reason):
            return "unsupported asset \(url.lastPathComponent): \(reason)"
        case .protectedContent(let url):
            return "protected content cannot be analysed: \(url.lastPathComponent)"
        case .analysisFailed(let url, let capabilities, let reason):
            let list = capabilities.map(\.rawValue).sorted().joined(separator: ", ")
            return "analysis of \(url.lastPathComponent) failed for [\(list)]: \(reason)"
        case .unsupportedCapabilities(let capabilities, let provider):
            let list = capabilities.map(\.rawValue).sorted().joined(separator: ", ")
            return "provider \(provider) does not support [\(list)]"
        case .missingResult(let capability, let provider):
            return "provider \(provider) returned no \(capability) result"
        case .providerUnavailable(let capability, let name):
            return "no provider available for \(capability)" + (name.map { " (selected: \($0))" } ?? "")
        case .providerMismatch(let capability, let name):
            return "provider \(name) is selected for \(capability) but does not implement it"
        case .unknownProvider(let name, let capability):
            return "no provider named \(name) is registered for \(capability)"
        }
    }
}
