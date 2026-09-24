import Foundation
import SwiftData

@Model
final class PCCRequestLog {
    var id: UUID = UUID()
    var timestamp: Date = Foundation.Date.now
    var sessionID: UUID = UUID()
    var sessionRequestNumber: Int = 0
    var dailyRequestNumber: Int = 0
    var globalRequestNumber: Int = 0
    var prompt: String = ""
    var response: String?
    var succeeded: Bool = false
    var errorType: String?
    var errorDescription: String?
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var outputInputRatio: Double?
    var reasoningOutputPercentage: Double?
    var outputTokensPerSecond: Double?
    var sessionAccumulatedTokens: Int?
    var contextSize: Int?
    var contextUsagePercentage: Double?
    var quotaStatusBefore: String?
    var quotaStatusAfter: String?
    var pccAvailabilityBefore: String?
    var pccAvailabilityAfter: String?
    var quotaResetDate: Date?
    var reasoningLevel: String?
    var maximumResponseTokens: Int?
    var startedAt: Date = Foundation.Date.now
    var completedAt: Date?
    var latencyMilliseconds: Int?
    var modelName: String = "PrivateCloudComputeLanguageModel"
    var contextErrorTokenCount: Int?
    var contextErrorSize: Int?
    var contextErrorDebugDescription: String?
    var firstApproachingObservationNumber: Int?
    var firstLimitReachedObservationNumber: Int?
    var experimentID: UUID?
    var experimentKind: String?
    var sessionBehavior: String?
    var containsImage: Bool = false
    var imageWidth: Int?
    var imageHeight: Int?
    var imageApproximateBytes: Int?
    var imageResolution: String?
    var contextUsageBefore: Int?
    var contextUsageAfter: Int?
    var observedContextIncrease: Int?

    init() {}
}

@Model
final class PCCQuotaObservation {
    var id: UUID = UUID()
    var timestamp: Date = Foundation.Date.now
    var status: String = "Unknown"
    var dailyRequestNumber: Int = 0
    var resetDate: Date?

    init() {}
}
