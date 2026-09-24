import Foundation
import FoundationModels
import Observation
import SwiftData
import CoreGraphics
import ImageIO

@Observable
@MainActor
final class PCCService {
    private(set) var status = "Checking…"
    private(set) var availabilityDetail: String?
    private(set) var quotaStatus = "Unknown"
    private(set) var quotaResetDate: Date?
    private(set) var quotaIsApproaching = false
    private(set) var quotaSuggestionAvailable = false
    private(set) var response: String?
    private(set) var errorMessage: String?
    private(set) var errorType: String?
    private(set) var duration: TimeInterval?
    private(set) var isLoading = false
    private(set) var requestState = "Not sent"
    private(set) var contextSize: Int?
    private(set) var contextSizeError: String?
    private(set) var sessionID = UUID()
    private(set) var sessionUsage: Int?
    private(set) var preflightTokenCountDescription = "Unavailable for PrivateCloudComputeLanguageModel"

    @available(iOS 27.0, *)
    private var model: PrivateCloudComputeLanguageModel { PrivateCloudComputeLanguageModel() }
    @available(iOS 27.0, *)
    private var session: LanguageModelSession?

    var isSessionResponding: Bool {
        if #available(iOS 27.0, *) { return session?.isResponding ?? false }
        return false
    }

    var contextUsagePercentage: Double? {
        guard let sessionUsage, let contextSize, contextSize > 0 else { return nil }
        return Double(sessionUsage) / Double(contextSize) * 100
    }

    var remainingContextTokens: Int? {
        guard let sessionUsage, let contextSize, contextSize > 0 else { return nil }
        return max(0, contextSize - sessionUsage)
    }

    func checkAvailability(modelContext: ModelContext? = nil) async {
        print("[PCC] Checking availability")
        guard #available(iOS 27.0, *) else {
            status = "Unavailable"
            availabilityDetail = "PrivateCloudComputeLanguageModel requires iOS 27.0 or later."
            quotaStatus = "Unavailable"
            return
        }
        do {
            contextSize = try await model.contextSize
            contextSizeError = nil
            print("[PCC] Context size: \(contextSize ?? 0)")
        } catch {
            contextSize = nil
            contextSizeError = error.localizedDescription
            print("[PCC] Context size unavailable: \(error.localizedDescription)")
        }
        refreshAvailabilityAndQuota()
        if let modelContext { recordQuotaTransition(in: modelContext, activeDailyRequestNumber: localDailyRequestCount(in: modelContext)) }
        if session == nil { startNewSession() }
    }

    func startNewSession() {
        guard #available(iOS 27.0, *) else { return }
        sessionID = UUID()
        session = LanguageModelSession(model: model)
        sessionUsage = session?.usage.totalTokenCount
        response = nil
        errorMessage = nil
        errorType = nil
        requestState = "Session ready"
        print("[PCC] New session: \(sessionID.uuidString)")
    }

    func reuseCurrentSession() {
        guard #available(iOS 27.0, *) else { return }
        if session == nil { startNewSession() }
        requestState = "Reusing current session"
    }

    func showQuotaIncreaseSuggestion() {
        guard #available(iOS 27.0, *) else { return }
        model.quotaUsage.limitIncreaseSuggestion?.show()
    }

    func send(
        prompt: String,
        reasoningLevel: PCCReasoningChoice,
        maximumResponseTokens: Int,
        modelContext: ModelContext,
        experimentID: UUID? = nil,
        experimentKind: String? = nil,
        sessionBehavior: String? = nil
    ) async {
        guard !isLoading, !isSessionResponding else { return }
        response = nil
        errorMessage = nil
        errorType = nil
        duration = nil
        requestState = "Checking PCC"

        guard #available(iOS 27.0, *) else {
            failWithoutRecord("API unavailable", "PrivateCloudComputeLanguageModel requires iOS 27.0 or later.")
            return
        }

        refreshAvailabilityAndQuota()
        if contextSize == nil {
            do { contextSize = try await model.contextSize; contextSizeError = nil }
            catch { contextSizeError = error.localizedDescription }
            refreshAvailabilityAndQuota()
        }
        if session == nil { startNewSession() }

        let startedAt = Date()
        let existingRecords = (try? modelContext.fetch(FetchDescriptor<PCCRequestLog>())) ?? []
        recordQuotaTransition(in: modelContext, activeDailyRequestNumber: existingRecords.filter { Calendar.current.isDateInToday($0.timestamp) }.count + 1)
        let todayRecords = existingRecords.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: startedAt) }
        let sessionRecords = existingRecords.filter { $0.sessionID == sessionID }
        let record = PCCRequestLog()
        record.id = UUID()
        record.timestamp = startedAt
        record.startedAt = startedAt
        record.sessionID = sessionID
        record.sessionRequestNumber = sessionRecords.count + 1
        record.dailyRequestNumber = todayRecords.count + 1
        record.globalRequestNumber = (existingRecords.map(\.globalRequestNumber).max() ?? 0) > 0
            ? (existingRecords.map(\.globalRequestNumber).max() ?? 0) + 1
            : existingRecords.count + 1
        record.prompt = prompt
        record.errorType = "Request pending"
        record.errorDescription = "PCC generation has been recorded locally and is in progress."
        record.quotaStatusBefore = quotaStatus
        record.quotaResetDate = quotaResetDate
        record.pccAvailabilityBefore = status
        record.contextSize = contextSize
        record.reasoningLevel = reasoningLevel.label
        record.maximumResponseTokens = maximumResponseTokens
        record.experimentID = experimentID
        record.experimentKind = experimentKind
        record.sessionBehavior = sessionBehavior

        if case .unavailable(let reason) = model.availability {
            record.errorType = "Model Unavailable"
            record.errorDescription = reasonDescription(reason)
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            guard persist(record, in: modelContext) else {
                failWithoutRecord("Local persistence failed", "The unavailable PCC attempt could not be saved locally.")
                return
            }
            fail("PCC unavailable", record.errorDescription ?? "The PCC model is unavailable.")
            return
        }

        if quotaStatus == "Limit Reached" {
            let detail = quotaResetDate.map { "PCC quota is already at its limit. Resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "PCC quota is already at its limit. Apple did not provide a reset date."
            record.errorType = "Quota Limit Reached"
            record.errorDescription = detail
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            guard persist(record, in: modelContext) else {
                failWithoutRecord("Local persistence failed", "The quota-blocked attempt could not be saved locally.")
                return
            }
            fail("PCC quota limit", detail)
            return
        }

        let used = session?.usage.totalTokenCount
        sessionUsage = used
        if let used, let contextSize, contextSize > 0, Double(used) / Double(contextSize) >= 0.95 {
            let detail = "Context nearly full. Start a new session before continuing."
            record.errorType = "Context safety threshold"
            record.errorDescription = detail
            record.sessionAccumulatedTokens = used
            record.contextUsagePercentage = Double(used) / Double(contextSize) * 100
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            guard persist(record, in: modelContext) else {
                failWithoutRecord("Local persistence failed", "The context-blocked attempt could not be saved locally.")
                return
            }
            fail("Context nearly full", detail)
            return
        }

        guard let session else {
            record.errorType = "PCC session unavailable"
            record.errorDescription = "Failed to create a PCC LanguageModelSession."
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            guard persist(record, in: modelContext) else {
                failWithoutRecord("Local persistence failed", "The PCC session failure could not be saved locally.")
                return
            }
            fail(record.errorType ?? "PCC session unavailable", record.errorDescription ?? "Unknown session error.")
            return
        }

        guard persist(record, in: modelContext) else {
            failWithoutRecord("Local persistence failed", "The request was not sent because SwiftData could not save its request record.")
            return
        }
        isLoading = true
        requestState = "In progress"
        defer { isLoading = false }
        print("[PCC] Creating LanguageModelSession for session \(sessionID.uuidString)")
        print("[PCC] Sending request #\(record.dailyRequestNumber); quota before: \(quotaStatus)")
        let clockStart = ContinuousClock.now
        do {
            let contextOptions = ContextOptions(reasoningLevel: reasoningLevel.foundationLevel)
            let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            let result = try await session.respond(to: prompt, options: options, contextOptions: contextOptions)
            let elapsed = clockStart.duration(to: .now)
            duration = seconds(elapsed)
            response = result.content
            requestState = "Successful"
            record.response = result.content
            record.succeeded = true
            record.errorType = nil
            record.errorDescription = nil
            record.inputTokens = result.usage.input.totalTokenCount
            record.cachedInputTokens = result.usage.input.cachedTokenCount
            record.outputTokens = result.usage.output.totalTokenCount
            record.reasoningTokens = result.usage.output.reasoningTokenCount
            record.totalTokens = result.usage.totalTokenCount
            if let input = record.inputTokens, input > 0, let output = record.outputTokens {
                record.outputInputRatio = Double(output) / Double(input)
            }
            if let output = record.outputTokens, output > 0, let reasoning = record.reasoningTokens {
                record.reasoningOutputPercentage = Double(reasoning) / Double(output) * 100
            }
            if let output = record.outputTokens, let latencyMilliseconds = record.latencyMilliseconds, latencyMilliseconds > 0 {
                record.outputTokensPerSecond = Double(output) / (Double(latencyMilliseconds) / 1_000)
            }
            record.sessionAccumulatedTokens = session.usage.totalTokenCount
            record.contextSize = contextSize
            record.contextUsagePercentage = contextSize.flatMap { $0 > 0 ? Double(session.usage.totalTokenCount) / Double($0) * 100 : nil }
            record.completedAt = Date()
            record.latencyMilliseconds = Int((duration ?? 0) * 1_000)
            if let output = record.outputTokens, let latencyMilliseconds = record.latencyMilliseconds, latencyMilliseconds > 0 {
                record.outputTokensPerSecond = Double(output) / (Double(latencyMilliseconds) / 1_000)
            }
            refreshAvailabilityAndQuota()
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            record.quotaResetDate = quotaResetDate
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            sessionUsage = session.usage.totalTokenCount
            try modelContext.save()
            print("[PCC] Response received; input=\(record.inputTokens ?? -1), cached=\(record.cachedInputTokens ?? -1), output=\(record.outputTokens ?? -1), reasoning=\(record.reasoningTokens ?? -1), response total=\(record.totalTokens ?? -1), session total=\(record.sessionAccumulatedTokens ?? -1)")
            print(String(format: "[PCC] Duration: %.2f seconds", duration ?? 0))
        } catch {
            duration = seconds(clockStart.duration(to: .now))
            record.completedAt = Date()
            record.latencyMilliseconds = Int((duration ?? 0) * 1_000)
            let details = Task.isCancelled ? (type: "Cancelled", message: "The PCC request was cancelled.", contextTokenCount: nil, contextSize: nil, contextDebugDescription: nil) : describe(error)
            record.errorType = details.type
            record.errorDescription = details.message
            record.contextErrorTokenCount = details.contextTokenCount
            record.contextErrorSize = details.contextSize
            record.contextErrorDebugDescription = details.contextDebugDescription
            record.sessionAccumulatedTokens = session.usage.totalTokenCount
            sessionUsage = session.usage.totalTokenCount
            refreshAvailabilityAndQuota()
            if let pccError = error as? PrivateCloudComputeLanguageModel.Error,
               case .quotaLimitReached(let quotaError) = pccError {
                quotaStatus = "Limit Reached"
                quotaResetDate = quotaError.resetDate
            }
            if details.type == "Context limit", let reportedSize = details.contextSize {
                contextSize = reportedSize
            }
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            record.quotaResetDate = quotaResetDate
            annotateQuotaObservation(record, existingRecords: existingRecords, now: startedAt)
            recordQuotaTransition(in: modelContext, activeDailyRequestNumber: record.dailyRequestNumber)
            try? modelContext.save()
            fail(details.type, details.message)
        }
    }

    func sendImage(
        prompt: String,
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        imageApproximateBytes: Int,
        imageResolution: String,
        reasoningLevel: PCCReasoningChoice = .default,
        maximumResponseTokens: Int = 512,
        modelContext: ModelContext
    ) async {
        guard !isLoading, !isSessionResponding else { return }
        response = nil
        errorMessage = nil
        errorType = nil
        duration = nil
        requestState = "Checking PCC"

        guard #available(iOS 27.0, *) else {
            failWithoutRecord("API unavailable", "PrivateCloudComputeLanguageModel requires iOS 27.0 or later.")
            return
        }
        refreshAvailabilityAndQuota()
        if contextSize == nil { contextSize = try? await model.contextSize }
        if session == nil { startNewSession() }

        let startedAt = Date()
        let existingRecords = (try? modelContext.fetch(FetchDescriptor<PCCRequestLog>())) ?? []
        let todayRecords = existingRecords.filter { Calendar.current.isDateInToday($0.timestamp) }
        recordQuotaTransition(in: modelContext, activeDailyRequestNumber: todayRecords.count + 1)
        let sessionRecords = existingRecords.filter { $0.sessionID == sessionID }
        let beforeUsage = session?.usage.totalTokenCount
        sessionUsage = beforeUsage
        let record = PCCRequestLog()
        record.timestamp = startedAt
        record.startedAt = startedAt
        record.sessionID = sessionID
        record.globalRequestNumber = (existingRecords.map(\.globalRequestNumber).max() ?? 0) > 0
            ? (existingRecords.map(\.globalRequestNumber).max() ?? 0) + 1 : existingRecords.count + 1
        record.dailyRequestNumber = todayRecords.count + 1
        record.sessionRequestNumber = sessionRecords.count + 1
        record.prompt = prompt
        record.reasoningLevel = reasoningLevel.label
        record.maximumResponseTokens = maximumResponseTokens
        record.quotaStatusBefore = quotaStatus
        record.quotaResetDate = quotaResetDate
        record.pccAvailabilityBefore = status
        record.contextSize = contextSize
        record.sessionAccumulatedTokens = beforeUsage
        record.contextUsageBefore = beforeUsage
        record.containsImage = true
        record.imageWidth = image.width
        record.imageHeight = image.height
        record.imageApproximateBytes = imageApproximateBytes
        record.imageResolution = imageResolution
        record.experimentKind = "PCC image understanding"
        record.sessionBehavior = "Same session image follow-up"
        record.errorType = "Request pending"
        record.errorDescription = "PCC image request recorded locally and in progress."

        func saveFailure(_ type: String, _ message: String) {
            record.errorType = type
            record.errorDescription = message
            record.completedAt = .now
            record.sessionAccumulatedTokens = session?.usage.totalTokenCount ?? beforeUsage
            record.contextUsageAfter = session?.usage.totalTokenCount
            if let before = record.contextUsageBefore, let after = record.contextUsageAfter {
                record.observedContextIncrease = after - before
            }
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            record.quotaResetDate = quotaResetDate
            contextSaveFailure(record, in: modelContext)
            fail(type, message)
        }

        if case .unavailable(let reason) = model.availability {
            saveFailure("Model Unavailable", reasonDescription(reason))
            return
        }
        if quotaStatus == "Limit Reached" {
            saveFailure("Quota Limit Reached", "PCC quota is already at its limit. Apple did not accept an image request.")
            return
        }
        if let beforeUsage, let contextSize, contextSize > 0, Double(beforeUsage) / Double(contextSize) >= 0.95 {
            saveFailure("Context safety threshold", "Context nearly full. Start a new PCC session before continuing.")
            return
        }
        guard let session else {
            saveFailure("PCC session unavailable", "Failed to create a PCC LanguageModelSession.")
            return
        }
        guard persist(record, in: modelContext) else {
            failWithoutRecord("Local persistence failed", "The image request was not sent because SwiftData could not save its request record.")
            return
        }

        isLoading = true
        requestState = "In progress"
        defer { isLoading = false }
        let clockStart = ContinuousClock.now
        do {
            let attachment = Attachment(image, orientation: orientation).label("test-image")
            let imagePrompt = Prompt {
                prompt
                attachment
            }
            let contextOptions = ContextOptions(reasoningLevel: reasoningLevel.foundationLevel)
            let result = try await session.respond(
                to: imagePrompt,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens),
                contextOptions: contextOptions
            )
            duration = seconds(clockStart.duration(to: .now))
            response = result.content
            requestState = "Successful"
            record.response = result.content
            record.succeeded = true
            record.errorType = nil
            record.errorDescription = nil
            record.inputTokens = result.usage.input.totalTokenCount
            record.cachedInputTokens = result.usage.input.cachedTokenCount
            record.outputTokens = result.usage.output.totalTokenCount
            record.reasoningTokens = result.usage.output.reasoningTokenCount
            record.totalTokens = result.usage.totalTokenCount
            record.sessionAccumulatedTokens = session.usage.totalTokenCount
            record.contextUsageAfter = session.usage.totalTokenCount
            if let before = record.contextUsageBefore, let after = record.contextUsageAfter {
                record.observedContextIncrease = after - before
            }
            record.contextSize = contextSize
            record.contextUsagePercentage = contextSize.flatMap { $0 > 0 ? Double(session.usage.totalTokenCount) / Double($0) * 100 : nil }
            record.completedAt = .now
            record.latencyMilliseconds = Int((duration ?? 0) * 1_000)
            if let input = record.inputTokens, input > 0, let output = record.outputTokens {
                record.outputInputRatio = Double(output) / Double(input)
            }
            if let output = record.outputTokens, output > 0, let reasoning = record.reasoningTokens {
                record.reasoningOutputPercentage = Double(reasoning) / Double(output) * 100
            }
            if let output = record.outputTokens, let milliseconds = record.latencyMilliseconds, milliseconds > 0 {
                record.outputTokensPerSecond = Double(output) / (Double(milliseconds) / 1_000)
            }
            sessionUsage = session.usage.totalTokenCount
            refreshAvailabilityAndQuota()
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            record.quotaResetDate = quotaResetDate
            recordQuotaTransition(in: modelContext, activeDailyRequestNumber: record.dailyRequestNumber)
            try modelContext.save()
        } catch {
            duration = seconds(clockStart.duration(to: .now))
            record.latencyMilliseconds = Int((duration ?? 0) * 1_000)
            let details = Task.isCancelled
                ? (type: "Cancelled", message: "The PCC image request was cancelled.", contextTokenCount: nil, contextSize: nil, contextDebugDescription: nil)
                : describe(error)
            record.errorType = details.type
            record.errorDescription = details.message
            record.contextErrorTokenCount = details.contextTokenCount
            record.contextErrorSize = details.contextSize
            record.contextErrorDebugDescription = details.contextDebugDescription
            record.sessionAccumulatedTokens = session.usage.totalTokenCount
            record.contextUsageAfter = session.usage.totalTokenCount
            if let before = record.contextUsageBefore, let after = record.contextUsageAfter {
                record.observedContextIncrease = after - before
            }
            sessionUsage = session.usage.totalTokenCount
            refreshAvailabilityAndQuota()
            if let pccError = error as? PrivateCloudComputeLanguageModel.Error,
               case .quotaLimitReached(let quotaError) = pccError {
                quotaStatus = "Limit Reached"
                quotaResetDate = quotaError.resetDate
            }
            record.quotaStatusAfter = quotaStatus
            record.pccAvailabilityAfter = status
            record.quotaResetDate = quotaResetDate
            record.completedAt = .now
            recordQuotaTransition(in: modelContext, activeDailyRequestNumber: record.dailyRequestNumber)
            try? modelContext.save()
            fail(details.type, details.message)
        }
    }

    private func contextSaveFailure(_ record: PCCRequestLog, in context: ModelContext) {
        context.insert(record)
        try? context.save()
    }

    @available(iOS 27.0, *)
    private func refreshAvailabilityAndQuota() {
        switch model.availability {
        case .available:
            status = "Available"
            availabilityDetail = nil
            print("[PCC] PCC available")
        case .unavailable(let reason):
            status = "Unavailable"
            availabilityDetail = reasonDescription(reason)
            print("[PCC] PCC unavailable: \(availabilityDetail ?? "Unknown")")
        @unknown default:
            status = "Unknown"
            availabilityDetail = "The SDK returned an unrecognized availability state."
        }
        NSLog("[PCC] Availability snapshot: \(String(reflecting: model.availability)); displayed status: \(status); detail: \(availabilityDetail ?? "Not provided")")

        let quota = model.quotaUsage
        quotaResetDate = quota.resetDate
        quotaSuggestionAvailable = quota.limitIncreaseSuggestion != nil
        switch quota.status {
        case .belowLimit(let below):
            quotaIsApproaching = below.isApproachingLimit
            quotaStatus = below.isApproachingLimit ? "Approaching Limit" : "Below Limit"
        case .limitReached:
            quotaIsApproaching = false
            quotaStatus = "Limit Reached"
        @unknown default:
            quotaIsApproaching = false
            quotaStatus = "Unknown"
        }
        print("[PCC] Quota status: \(quotaStatus)")
    }

    private func persist(_ record: PCCRequestLog, in context: ModelContext) -> Bool {
        context.insert(record)
        do {
            try context.save()
            return true
        } catch {
            context.delete(record)
            print("[PCC] Could not persist request before generation: \(error.localizedDescription)")
            return false
        }
    }

    private func localDailyRequestCount(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<PCCRequestLog>())) ?? []
        return records.filter { Calendar.current.isDateInToday($0.timestamp) }.count
    }

    private func recordQuotaTransition(in context: ModelContext, activeDailyRequestNumber: Int) {
        let observations = (try? context.fetch(FetchDescriptor<PCCQuotaObservation>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))) ?? []
        guard observations.first?.status != quotaStatus else { return }
        let observation = PCCQuotaObservation()
        observation.timestamp = .now
        observation.status = quotaStatus
        observation.dailyRequestNumber = activeDailyRequestNumber
        observation.resetDate = quotaResetDate
        context.insert(observation)
        try? context.save()
    }

    private func annotateQuotaObservation(_ record: PCCRequestLog, existingRecords: [PCCRequestLog], now: Date) {
        let today = existingRecords.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: now) }
        let statuses = today.flatMap { [$0.quotaStatusBefore, $0.quotaStatusAfter].compactMap { $0 } }
        if (record.quotaStatusBefore == "Approaching Limit" || record.quotaStatusAfter == "Approaching Limit"),
           !statuses.contains("Approaching Limit") {
            record.firstApproachingObservationNumber = record.dailyRequestNumber
        }
        if (record.quotaStatusBefore == "Limit Reached" || record.quotaStatusAfter == "Limit Reached"),
           !statuses.contains("Limit Reached") {
            record.firstLimitReachedObservationNumber = record.dailyRequestNumber
        }
    }

    private func reasonDescription(_ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device or Simulator configuration is not eligible for PCC."
        case .systemNotReady: "Apple Intelligence or the PCC system service is not ready."
        @unknown default: "The SDK returned an unrecognized unavailable reason: \(String(describing: reason))"
        }
    }

    private func describe(_ error: Error) -> (type: String, message: String, contextTokenCount: Int?, contextSize: Int?, contextDebugDescription: String?) {
        if let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            switch pccError {
            case .networkFailure(let detail): return ("PCC network failure", detail.debugDescription, nil, nil, nil)
            case .quotaLimitReached(let detail):
                let reset = detail.resetDate.map { " Reset: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? " Apple did not provide a reset date."
                return ("Quota Limit Reached", detail.debugDescription + reset, nil, nil, nil)
            case .serviceUnavailable(let detail): return ("Model Unavailable", detail.debugDescription, nil, nil, nil)
            @unknown default: return ("Unknown PCC error", pccError.localizedDescription, nil, nil, nil)
            }
        }
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded(let detail):
                return ("Context Size Exceeded", "\(detail.debugDescription) Reported token count: \(detail.tokenCount); context size: \(detail.contextSize).", detail.tokenCount, detail.contextSize, detail.debugDescription)
            case .rateLimited(let detail):
                let reset = detail.resetDate.map { " Reset: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                return ("Rate Limited", detail.debugDescription + reset, nil, nil, nil)
            case .timeout(let detail): return ("Timeout", detail.debugDescription, nil, nil, nil)
            case .refusal(let detail): return ("Refusal", detail.debugDescription, nil, nil, nil)
            case .guardrailViolation(let detail): return ("Guardrail violation", detail.debugDescription, nil, nil, nil)
            case .unsupportedCapability(let detail): return ("Unsupported capability", detail.debugDescription, nil, nil, nil)
            case .unsupportedTranscriptContent(let detail): return ("Unsupported Content", detail.debugDescription, nil, nil, nil)
            case .unsupportedLanguageOrLocale(let detail): return ("Unsupported language or locale", detail.debugDescription, nil, nil, nil)
            case .unsupportedGenerationGuide(let detail): return ("Unsupported generation guide", detail.debugDescription, nil, nil, nil)
            @unknown default: return ("Unknown Foundation Models error", error.localizedDescription, nil, nil, nil)
            }
        }
        return (String(reflecting: type(of: error)), error.localizedDescription, nil, nil, nil)
    }

    private func fail(_ type: String, _ message: String) {
        response = nil
        errorType = type
        errorMessage = message
        requestState = "Failed"
        print("[PCC] REQUEST FAILED")
        print("[PCC] Error type: \(type)")
        print("[PCC] Error: \(message)")
    }

    private func failWithoutRecord(_ type: String, _ message: String) {
        fail(type, message)
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum PCCReasoningChoice: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case light = "Light"
    case moderate = "Moderate"
    case deep = "Deep"

    var id: String { rawValue }
    var label: String { rawValue }

    @available(iOS 27.0, *)
    var foundationLevel: ContextOptions.ReasoningLevel? {
        switch self {
        case .default: return nil
        case .light: return .light
        case .moderate: return .moderate
        case .deep: return .deep
        }
    }
}
