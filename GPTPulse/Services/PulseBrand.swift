import Foundation

enum PulseBrand {
    static let displayName = "LLM Pulse"
    static let legacyDisplayName = "GPT Pulse"

    // These identifiers intentionally remain stable so existing users keep
    // their preferences, receipts, notification permissions, and updates.
    static let technicalIdentifier = "gpt-pulse"
    static let bundleIdentifier = "com.zuuzii.GPTPulse"
    static let legacyApplicationSupportDirectoryName = "GPT Pulse"

    static let repositorySlug = "zuuzii-org/llm-pulse"
    static let repositoryURL = URL(string: "https://github.com/zuuzii-org/llm-pulse")!
    static let updateFeedURL = URL(
        string: "https://github.com/zuuzii-org/llm-pulse/releases/latest/download/appcast.xml"
    )!
}
