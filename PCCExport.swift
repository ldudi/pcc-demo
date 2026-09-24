import Foundation

enum PCCExport {
    static func write(_ records: [PCCRequestLog], quotaObservations: [PCCQuotaObservation] = []) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PCCLimitsLabExport", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let jsonURL = folder.appendingPathComponent("pcc-experiments-\(stamp).json")
        let csvURL = folder.appendingPathComponent("pcc-experiments-\(stamp).csv")
        let quotaJSONURL = folder.appendingPathComponent("pcc-quota-history-\(stamp).json")
        let quotaCSVURL = folder.appendingPathComponent("pcc-quota-history-\(stamp).csv")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records.map(PCCExportRecord.init)).write(to: jsonURL, options: .atomic)
        try csv(records).write(to: csvURL, atomically: true, encoding: .utf8)
        try encoder.encode(quotaObservations.map(PCCQuotaExportRecord.init)).write(to: quotaJSONURL, options: .atomic)
        let quotaRows = quotaObservations.map { item in
            [ISO8601DateFormatter().string(from: item.timestamp), item.status, String(item.dailyRequestNumber), item.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
                .map(csvEscape).joined(separator: ",")
        }
        try (["timestamp,status,daily_request_number,reset_date"] + quotaRows).joined(separator: "\n").write(to: quotaCSVURL, atomically: true, encoding: .utf8)
        return [jsonURL, csvURL, quotaJSONURL, quotaCSVURL]
    }

    private static func csv(_ records: [PCCRequestLog]) -> String {
        let columns: [(String, (PCCRequestLog) -> String)] = [
            ("id", { $0.id.uuidString }), ("timestamp", { ISO8601DateFormatter().string(from: $0.timestamp) }),
            ("global_request_number", { String($0.globalRequestNumber) }), ("session_id", { $0.sessionID.uuidString }), ("session_request_number", { "\($0.sessionRequestNumber)" }),
            ("daily_request_number", { "\($0.dailyRequestNumber)" }), ("prompt", { $0.prompt }), ("response", { $0.response ?? "" }),
            ("succeeded", { "\($0.succeeded)" }), ("error_type", { $0.errorType ?? "" }), ("error_description", { $0.errorDescription ?? "" }),
            ("input_tokens", { $0.inputTokens.map { String($0) } ?? "" }), ("cached_input_tokens", { $0.cachedInputTokens.map { String($0) } ?? "" }),
            ("output_tokens", { $0.outputTokens.map { String($0) } ?? "" }), ("reasoning_tokens", { $0.reasoningTokens.map { String($0) } ?? "" }),
            ("total_tokens", { $0.totalTokens.map { String($0) } ?? "" }), ("output_input_ratio", { $0.outputInputRatio.map { String($0) } ?? "" }),
            ("reasoning_output_percentage", { $0.reasoningOutputPercentage.map { String($0) } ?? "" }), ("output_tokens_per_second", { $0.outputTokensPerSecond.map { String($0) } ?? "" }),
            ("session_accumulated_tokens", { $0.sessionAccumulatedTokens.map { String($0) } ?? "" }),
            ("context_size", { $0.contextSize.map { String($0) } ?? "" }), ("context_usage_percentage", { $0.contextUsagePercentage.map { String($0) } ?? "" }),
            ("quota_status_before", { $0.quotaStatusBefore ?? "" }), ("quota_status_after", { $0.quotaStatusAfter ?? "" }),
            ("pcc_availability_before", { $0.pccAvailabilityBefore ?? "" }), ("pcc_availability_after", { $0.pccAvailabilityAfter ?? "" }),
            ("quota_reset_date", { $0.quotaResetDate.map { ISO8601DateFormatter().string(from: $0) } ?? "" }),
            ("reasoning_level", { $0.reasoningLevel ?? "" }), ("experiment_id", { $0.experimentID?.uuidString ?? "" }),
            ("experiment_kind", { $0.experimentKind ?? "" }), ("session_behavior", { $0.sessionBehavior ?? "" }),
            ("contains_image", { String($0.containsImage) }), ("image_width", { $0.imageWidth.map { String($0) } ?? "" }),
            ("image_height", { $0.imageHeight.map { String($0) } ?? "" }), ("image_approximate_bytes", { $0.imageApproximateBytes.map { String($0) } ?? "" }),
            ("image_resolution", { $0.imageResolution ?? "" }), ("context_usage_before", { $0.contextUsageBefore.map { String($0) } ?? "" }),
            ("context_usage_after", { $0.contextUsageAfter.map { String($0) } ?? "" }), ("observed_context_increase", { $0.observedContextIncrease.map { String($0) } ?? "" }),
            ("maximum_response_tokens", { $0.maximumResponseTokens.map { String($0) } ?? "" }),
            ("started_at", { ISO8601DateFormatter().string(from: $0.startedAt) }),
            ("completed_at", { $0.completedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "" }),
            ("latency_milliseconds", { $0.latencyMilliseconds.map { String($0) } ?? "" }), ("model_name", { $0.modelName }),
            ("context_error_token_count", { $0.contextErrorTokenCount.map { String($0) } ?? "" }),
            ("context_error_size", { $0.contextErrorSize.map { String($0) } ?? "" }),
            ("context_error_debug_description", { $0.contextErrorDebugDescription ?? "" }),
            ("first_approaching_observation_number", { $0.firstApproachingObservationNumber.map { String($0) } ?? "" }),
            ("first_limit_reached_observation_number", { $0.firstLimitReachedObservationNumber.map { String($0) } ?? "" })
        ]
        return ([columns.map { csvEscape($0.0) }.joined(separator: ",")] + records.map { record in
            columns.map { csvEscape($0.1(record)) }.joined(separator: ",")
        }).joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct PCCQuotaExportRecord: Encodable {
    let id: UUID
    let timestamp: Date
    let status: String
    let dailyRequestNumber: Int
    let resetDate: Date?

    init(_ observation: PCCQuotaObservation) {
        id = observation.id
        timestamp = observation.timestamp
        status = observation.status
        dailyRequestNumber = observation.dailyRequestNumber
        resetDate = observation.resetDate
    }
}

private struct PCCExportRecord: Encodable {
    let id: UUID
    let timestamp: Date
    let sessionID: UUID
    let globalRequestNumber: Int
    let sessionRequestNumber: Int
    let dailyRequestNumber: Int
    let prompt: String
    let response: String?
    let succeeded: Bool
    let errorType: String?
    let errorDescription: String?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let outputInputRatio: Double?
    let reasoningOutputPercentage: Double?
    let outputTokensPerSecond: Double?
    let sessionAccumulatedTokens: Int?
    let contextSize: Int?
    let contextUsagePercentage: Double?
    let quotaStatusBefore: String?
    let quotaStatusAfter: String?
    let pccAvailabilityBefore: String?
    let pccAvailabilityAfter: String?
    let quotaResetDate: Date?
    let reasoningLevel: String?
    let maximumResponseTokens: Int?
    let startedAt: Date
    let completedAt: Date?
    let latencyMilliseconds: Int?
    let modelName: String
    let contextErrorTokenCount: Int?
    let contextErrorSize: Int?
    let contextErrorDebugDescription: String?
    let firstApproachingObservationNumber: Int?
    let firstLimitReachedObservationNumber: Int?
    let experimentID: UUID?
    let experimentKind: String?
    let sessionBehavior: String?
    let containsImage: Bool
    let imageWidth: Int?
    let imageHeight: Int?
    let imageApproximateBytes: Int?
    let imageResolution: String?
    let contextUsageBefore: Int?
    let contextUsageAfter: Int?
    let observedContextIncrease: Int?

    init(_ record: PCCRequestLog) {
        id = record.id
        timestamp = record.timestamp
        sessionID = record.sessionID
        globalRequestNumber = record.globalRequestNumber
        sessionRequestNumber = record.sessionRequestNumber
        dailyRequestNumber = record.dailyRequestNumber
        prompt = record.prompt
        response = record.response
        succeeded = record.succeeded
        errorType = record.errorType
        errorDescription = record.errorDescription
        inputTokens = record.inputTokens
        cachedInputTokens = record.cachedInputTokens
        outputTokens = record.outputTokens
        reasoningTokens = record.reasoningTokens
        totalTokens = record.totalTokens
        outputInputRatio = record.outputInputRatio
        reasoningOutputPercentage = record.reasoningOutputPercentage
        outputTokensPerSecond = record.outputTokensPerSecond
        sessionAccumulatedTokens = record.sessionAccumulatedTokens
        contextSize = record.contextSize
        contextUsagePercentage = record.contextUsagePercentage
        quotaStatusBefore = record.quotaStatusBefore
        quotaStatusAfter = record.quotaStatusAfter
        pccAvailabilityBefore = record.pccAvailabilityBefore
        pccAvailabilityAfter = record.pccAvailabilityAfter
        quotaResetDate = record.quotaResetDate
        reasoningLevel = record.reasoningLevel
        maximumResponseTokens = record.maximumResponseTokens
        startedAt = record.startedAt
        completedAt = record.completedAt
        latencyMilliseconds = record.latencyMilliseconds
        modelName = record.modelName
        contextErrorTokenCount = record.contextErrorTokenCount
        contextErrorSize = record.contextErrorSize
        contextErrorDebugDescription = record.contextErrorDebugDescription
        firstApproachingObservationNumber = record.firstApproachingObservationNumber
        firstLimitReachedObservationNumber = record.firstLimitReachedObservationNumber
        experimentID = record.experimentID
        experimentKind = record.experimentKind
        sessionBehavior = record.sessionBehavior
        containsImage = record.containsImage
        imageWidth = record.imageWidth
        imageHeight = record.imageHeight
        imageApproximateBytes = record.imageApproximateBytes
        imageResolution = record.imageResolution
        contextUsageBefore = record.contextUsageBefore
        contextUsageAfter = record.contextUsageAfter
        observedContextIncrease = record.observedContextIncrease
    }
}
