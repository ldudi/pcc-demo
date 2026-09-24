import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import ImageIO

struct LabDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var records: [PCCRequestLog]
    @Query(sort: \PCCQuotaObservation.timestamp, order: .reverse) private var quotaObservations: [PCCQuotaObservation]
    @State private var service = PCCService()
    @State private var prompt = "Explain how TCP differs from UDP in five concise bullet points."
    @State private var reasoning: PCCReasoningChoice = .default
    @State private var maximumResponseTokens = "512"
    @State private var didRecoverInterruptedRequests = false

    private var todayRecords: [PCCRequestLog] {
        records.filter { Calendar.current.isDateInToday($0.timestamp) }
    }
    private var successCount: Int { todayRecords.filter(\.succeeded).count }
    private var failureCount: Int { todayRecords.filter { !$0.succeeded && $0.errorType != "Request pending" }.count }
    private var sessionRequestCount: Int { records.filter { $0.sessionID == service.sessionID }.count }
    private var contextBand: String? {
        guard let value = service.contextUsagePercentage else { return nil }
        switch value {
        case 95...: return "Critical"
        case 85..<95: return "Near Limit"
        case 70..<85: return "Getting Full"
        default: return "Normal"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("PCC", value: service.status)
                LabeledContent("Quota", value: service.quotaStatus)
                LabeledContent("Reset", value: service.quotaResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "Not provided")
                if let detail = service.availabilityDetail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if service.quotaIsApproaching {
                    Label("PCC reports that this account is approaching its quota. Your local request count is not Apple's quota count.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if service.quotaStatus == "Limit Reached" {
                    Label("Apple reports the PCC quota limit is reached. No generation will be sent.", systemImage: "hand.raised.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
                if service.quotaSuggestionAvailable {
                    Button("View Apple quota options") { service.showQuotaIncreaseSuggestion() }
                }
            } header: { Text("PCC Limits Lab") }

            Section("Context Experiment") {
                LabeledContent("Session requests", value: "\(sessionRequestCount)")
                LabeledContent("Context size", value: service.contextSize.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                LabeledContent("Current session usage", value: service.sessionUsage.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                LabeledContent("Context used", value: service.contextUsagePercentage.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                LabeledContent("Remaining context", value: service.remainingContextTokens.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                LabeledContent("Safety state", value: contextBand ?? "Unavailable")
                LabeledContent("Exact preflight token count", value: service.preflightTokenCountDescription)
                if let contextError = service.contextSizeError {
                    Text("Context size error: \(contextError)").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Context safety thresholds are local warnings: Normal below 70%, Getting Full at 70%, Near Limit at 85%, Critical at 95%. They are not Apple limits.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let percent = service.contextUsagePercentage, percent >= 70 {
                    Label("Context is getting full. Consider starting a new session before continuing.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(percent >= 95 ? .red : .orange)
                }
                if let percent = service.contextUsagePercentage, percent >= 95 {
                    Text("Context nearly full. Start a new session before continuing.")
                        .font(.headline).foregroundStyle(.red)
                    Button("New Session", systemImage: "plus.circle", action: service.startNewSession)
                        .buttonStyle(.borderedProminent)
                }
            }

            Section("Requests Today · Our Local Records") {
                LabeledContent("Attempted", value: "\(todayRecords.count)")
                LabeledContent("Succeeded", value: "\(successCount)")
                LabeledContent("Failed", value: "\(failureCount)")
                LabeledContent("Apple exact requests remaining", value: "Not exposed by Apple")
                Text("These counts come from this app's saved attempts. They do not represent Apple's hidden quota counter.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let first = todayRecords.compactMap(\.firstApproachingObservationNumber).min() {
                    LabeledContent("First approaching-limit observation", value: "Request #\(first) today")
                }
                if let first = todayRecords.compactMap(\.firstLimitReachedObservationNumber).min() {
                    LabeledContent("First limit-reached observation", value: "Request #\(first) today")
                }
            }

            Section("Experiment Dashboard") {
                LabeledContent("Today tokens", value: tokenSum(todayRecords).map { $0.formatted() } ?? "Unavailable")
                LabeledContent("Average input", value: average(todayRecords, \.inputTokens).map { "\($0) tokens" } ?? "Unavailable")
                LabeledContent("Average output", value: average(todayRecords, \.outputTokens).map { "\($0) tokens" } ?? "Unavailable")
                LabeledContent("Average latency", value: averageLatency(todayRecords).map { String(format: "%.2f sec", $0) } ?? "Unavailable")
                LabeledContent("All-time requests", value: "\(records.count)")
                LabeledContent("All-time tokens", value: tokenSum(records).map { $0.formatted() } ?? "Unavailable")
                LabeledContent("Average reasoning tokens", value: average(records, \.reasoningTokens).map(String.init) ?? "Unavailable")
                LabeledContent("Cached input share", value: cachedShare(records).map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                LabeledContent("Rate-limit errors", value: "\(records.filter { $0.errorType?.localizedCaseInsensitiveContains("rate limit") == true }.count)")
                LabeledContent("Context-limit errors", value: "\(records.filter { $0.errorType?.localizedCaseInsensitiveContains("context") == true }.count)")
                ForEach(["Approaching Limit", "Limit Reached"], id: \.self) { status in
                    let first = quotaObservations.last { $0.status == status }
                    LabeledContent("First \(status)", value: first.map { "\($0.timestamp.formatted(date: .abbreviated, time: .shortened)) · today #\($0.dailyRequestNumber)" } ?? "Not observed")
                }
                NavigationLink("Daily Statistics") { DailyStatisticsView() }
                NavigationLink("Quota History") { QuotaHistoryView() }
            }

            Section("Prompt") {
                TextEditor(text: $prompt).frame(minHeight: 105).accessibilityLabel("PCC prompt")
                Picker("Reasoning level", selection: $reasoning) {
                    ForEach(PCCReasoningChoice.allCases) { choice in Text(choice.label).tag(choice) }
                }
                TextField("Maximum response tokens", text: $maximumResponseTokens)
                    .keyboardType(.numberPad)
                HStack {
                    Button("Reuse Current Session", systemImage: "arrow.clockwise") { service.reuseCurrentSession() }
                        .buttonStyle(.bordered)
                    Button("New Session", systemImage: "plus.circle") { service.startNewSession() }
                        .buttonStyle(.bordered)
                }
                Text("Session ID: \(service.sessionID.uuidString)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Button {
                    guard let maxTokens = Int(maximumResponseTokens), maxTokens > 0 else { return }
                    Task {
                        await service.send(
                            prompt: prompt,
                            reasoningLevel: reasoning,
                            maximumResponseTokens: maxTokens,
                            modelContext: modelContext
                        )
                    }
                } label: {
                    HStack {
                        if service.isLoading || service.isSessionResponding { ProgressView() }
                        Text((service.isLoading || service.isSessionResponding) ? "Contacting PCC…" : "Send to PCC")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isLoading || service.isSessionResponding || (service.contextUsagePercentage ?? 0) >= 95 || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(maximumResponseTokens).map { $0 <= 0 } != false)
            }

            Section("Latest Result") {
                if let response = service.response {
                    Text(response).textSelection(.enabled)
                    LabeledContent("Request", value: service.requestState)
                } else if let errorMessage = service.errorMessage {
                    Label(service.errorType ?? "Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage).textSelection(.enabled)
                } else {
                    Text("No request sent in this app run.").foregroundStyle(.secondary)
                }
                if let duration = service.duration {
                    LabeledContent("Latency", value: String(format: "%.2f sec", duration))
                }
            }
        }
        .navigationTitle("PCC Limits Lab")
        .task {
            if !didRecoverInterruptedRequests {
                didRecoverInterruptedRequests = true
                // Lightweight migration for rows saved before global request numbering existed.
                for (index, record) in records.sorted(by: { $0.timestamp < $1.timestamp }).enumerated() where record.globalRequestNumber <= 0 {
                    record.globalRequestNumber = index + 1
                }
                for record in records where record.succeeded {
                    if record.outputInputRatio == nil, let input = record.inputTokens, input > 0, let output = record.outputTokens {
                        record.outputInputRatio = Double(output) / Double(input)
                    }
                    if record.reasoningOutputPercentage == nil, let output = record.outputTokens, output > 0, let reasoning = record.reasoningTokens {
                        record.reasoningOutputPercentage = Double(reasoning) / Double(output) * 100
                    }
                    if record.outputTokensPerSecond == nil, let output = record.outputTokens, let milliseconds = record.latencyMilliseconds, milliseconds > 0 {
                        record.outputTokensPerSecond = Double(output) / (Double(milliseconds) / 1_000)
                    }
                }
                for record in records where !record.succeeded && record.errorType == "Request pending" && record.completedAt == nil {
                    record.errorType = "Interrupted request"
                    record.errorDescription = "The app ended before PCC returned a result. The request attempt was retained; its final PCC outcome is unknown."
                    record.completedAt = Date()
                    record.latencyMilliseconds = Int(max(0, Date().timeIntervalSince(record.startedAt) * 1_000))
                }
                if modelContext.hasChanges { try? modelContext.save() }
            }
            await service.checkAvailability(modelContext: modelContext)
        }
    }

    private func tokenSum(_ rows: [PCCRequestLog]) -> Int? {
        let values = rows.compactMap(\.totalTokens)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private func average(_ rows: [PCCRequestLog], _ keyPath: KeyPath<PCCRequestLog, Int?>) -> Int? {
        let values = rows.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
    private func averageLatency(_ rows: [PCCRequestLog]) -> Double? {
        let values = rows.compactMap(\.latencyMilliseconds)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count) / 1_000
    }
    private func cachedShare(_ rows: [PCCRequestLog]) -> Double? {
        let cached = rows.compactMap(\.cachedInputTokens), input = rows.compactMap(\.inputTokens)
        guard !cached.isEmpty, !input.isEmpty, input.reduce(0, +) > 0 else { return nil }
        return Double(cached.reduce(0, +)) / Double(input.reduce(0, +)) * 100
    }
}

struct HistoryView: View {
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var records: [PCCRequestLog]
    @Query(sort: \PCCQuotaObservation.timestamp, order: .reverse) private var quotaObservations: [PCCQuotaObservation]
    @State private var filter: HistoryFilter = .all
    @State private var exportError: String?
    @State private var exportedFiles: [URL] = []

    private var filtered: [PCCRequestLog] { records.filter { filter.includes($0) } }
    private var inputTotal: Int? { sum(\.inputTokens) }
    private var outputTotal: Int? { sum(\.outputTokens) }
    private var reasoningTotal: Int? { sum(\.reasoningTokens) }
    private var totalTokens: Int? { sum(\.totalTokens) }
    private var averageLatency: Double? {
        let values = records.compactMap(\.latencyMilliseconds)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count) / 1_000
    }

    var body: some View {
        List {
            Section("All Recorded Experiments") {
                LabeledContent("Requests", value: "\(records.count)")
                LabeledContent("Input tokens", value: formatted(inputTotal))
                LabeledContent("Output tokens", value: formatted(outputTotal))
                LabeledContent("Reasoning tokens", value: formatted(reasoningTotal))
                LabeledContent("Total observed tokens", value: formatted(totalTokens))
                LabeledContent("Average latency", value: averageLatency.map { String(format: "%.2f sec", $0) } ?? "Unavailable")
                Text("Historical token totals add measurements across requests and sessions. They are not a context-window size or Apple's quota counter.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                ForEach(filtered) { record in
                    NavigationLink {
                        RequestDetailView(record: record)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("#\(record.dailyRequestNumber)  \(record.succeeded ? "SUCCESS" : (record.errorType == "Request pending" ? "PENDING" : (record.errorType ?? "FAILED").uppercased()))")
                                    .font(.headline)
                                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Session \(record.sessionID.uuidString.prefix(8)) · turn \(record.sessionRequestNumber)")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(record.totalTokens.map { "\($0) tokens" } ?? "Tokens unavailable")
                                Text(record.latencyMilliseconds.map { String(format: "%.2f sec", Double($0) / 1_000) } ?? "—")
                                Text(record.reasoningLevel ?? "Default")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("History") }
            Section("Export") {
                Button("Prepare JSON and CSV exports", systemImage: "square.and.arrow.up") {
                    do { exportedFiles = try PCCExport.write(records, quotaObservations: quotaObservations) ; exportError = nil }
                    catch { exportError = error.localizedDescription }
                }
                ForEach(exportedFiles, id: \.self) { url in
                    ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "doc") }
                }
                if let exportError { Text(exportError).foregroundStyle(.red) }
                Text("Exports contain request prompts, responses, and saved usage data only. Keep the files local if your prompts are private.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("History")
    }

    private func sum(_ keyPath: KeyPath<PCCRequestLog, Int?>) -> Int? {
        let values = records.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
    private func formatted(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unavailable" }
}

struct UsageView: View {
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var records: [PCCRequestLog]
    private var today: [PCCRequestLog] { records.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var attemptedTokens: Int? {
        let values = today.compactMap(\.totalTokens)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private var firstApproaching: Int? { today.compactMap(\.firstApproachingObservationNumber).min() }
    private var firstReached: Int? { today.compactMap(\.firstLimitReachedObservationNumber).min() }

    var body: some View {
        List {
            Section("Today's PCC Usage") {
                LabeledContent("Requests attempted", value: "\(today.count)")
                LabeledContent("Successful", value: "\(today.filter(\.succeeded).count)")
                LabeledContent("Failed", value: "\(today.filter { !$0.succeeded }.count)")
                LabeledContent("Tokens processed", value: attemptedTokens.map { $0.formatted() } ?? "Unavailable")
                LabeledContent("Current observed Apple quota", value: today.first?.quotaStatusAfter ?? today.first?.quotaStatusBefore ?? "Unavailable")
                LabeledContent("Approaching limit", value: today.first?.quotaStatusAfter == "Approaching Limit" ? "Yes" : "No observed state")
                LabeledContent("Reset date", value: today.first?.quotaResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "Not exposed")
                LabeledContent("Exact daily allowance", value: "Not exposed by Apple's public API")
                Text("Your request counts and token totals are local observations. They are not Apple's hidden quota values.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let firstApproaching { LabeledContent("First approaching-limit observation", value: "Request #\(firstApproaching) today") }
                if let firstReached { LabeledContent("First limit-reached observation", value: "Request #\(firstReached) today") }
            }
            Section("Limits are different") {
                LabeledContent("Context limit", value: "Runtime context size; shared by the active session transcript")
                LabeledContent("Daily PCC quota", value: "Apple's per-user request quota state; exact remaining requests are not exposed")
                LabeledContent("Rate limiting", value: "A separate short-term Foundation Models error; recorded without automatic retry")
            }
        }
        .navigationTitle("Usage")
    }
}

struct RequestDetailView: View {
    let record: PCCRequestLog
    private var reasoningShare: Double? {
        guard let output = record.outputTokens, output > 0, let reasoning = record.reasoningTokens else { return nil }
        return Double(reasoning) / Double(output) * 100
    }

    var body: some View {
        List {
            Section("Request #\(record.dailyRequestNumber)") {
                LabeledContent("Global request", value: "#\(record.globalRequestNumber > 0 ? record.globalRequestNumber : record.dailyRequestNumber)")
                LabeledContent("Today", value: "#\(record.dailyRequestNumber)")
                LabeledContent("Date", value: record.timestamp.formatted(date: .complete, time: .shortened))
                LabeledContent("Status", value: record.succeeded ? "SUCCESS" : (record.errorType == "Request pending" ? "IN PROGRESS" : "FAILED"))
                LabeledContent("Model", value: record.modelName)
                LabeledContent("Session", value: record.sessionID.uuidString)
                LabeledContent("Session request", value: "\(record.sessionRequestNumber)")
                if let behavior = record.sessionBehavior { LabeledContent("Session behavior", value: behavior) }
                if let experiment = record.experimentKind { LabeledContent("Experiment", value: "\(experiment) · \(record.experimentID?.uuidString.prefix(8) ?? "—")") }
                if let latency = record.latencyMilliseconds { LabeledContent("Latency", value: String(format: "%.2f sec", Double(latency) / 1_000)) }
            }
            Section("Prompt") { Text(record.prompt).textSelection(.enabled) }
            Section("Response") {
                if let response = record.response { Text(response).textSelection(.enabled) }
                else { Text(record.errorDescription ?? "No response").textSelection(.enabled).foregroundStyle(record.succeeded ? Color.primary : Color.red) }
            }
            Section("Token Usage") {
                metric("Input", record.inputTokens)
                metric("Cached input", record.cachedInputTokens)
                metric("Output", record.outputTokens)
                metric("Reasoning", record.reasoningTokens)
                metric("Total response usage", record.totalTokens)
                metric("Session accumulated", record.sessionAccumulatedTokens)
                LabeledContent("Output / input ratio", value: record.outputInputRatio.map { String(format: "%.2f×", $0) } ?? "Unavailable")
                LabeledContent("Reasoning share of output", value: (record.reasoningOutputPercentage ?? reasoningShare).map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                LabeledContent("Output tokens per second", value: record.outputTokensPerSecond.map { String(format: "%.2f", $0) } ?? "Unavailable")
                metric("Context size", record.contextSize)
                LabeledContent("Context utilization", value: record.contextUsagePercentage.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                if let count = record.contextErrorTokenCount { metric("Context error token count", count) }
                if let size = record.contextErrorSize { metric("Context error size", size) }
                if let debug = record.contextErrorDebugDescription { LabeledContent("Context error debug", value: debug) }
            }
            if record.containsImage {
                Section("Image Attachment") {
                    LabeledContent("Contains image", value: "Yes")
                    LabeledContent("Dimensions", value: imageDimensions)
                    LabeledContent("Approximate bytes", value: record.imageApproximateBytes.map { $0.formatted() } ?? "Unavailable")
                    LabeledContent("Image size choice", value: record.imageResolution ?? "Original")
                    LabeledContent("Context before", value: record.contextUsageBefore.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                    LabeledContent("Context after", value: record.contextUsageAfter.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                    LabeledContent("Observed context increase", value: record.observedContextIncrease.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                    Text("Observed context increase reflects the session's total measured change. The public API does not identify image-only tokens.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Request Configuration") {
                LabeledContent("Reasoning", value: record.reasoningLevel ?? "Default")
                metric("Maximum response tokens", record.maximumResponseTokens)
                LabeledContent("Preflight token count", value: "Unavailable for this PCC model")
                LabeledContent("Quota before", value: record.quotaStatusBefore ?? "Unavailable")
                LabeledContent("Quota after", value: record.quotaStatusAfter ?? "Unavailable")
                LabeledContent("PCC availability before", value: record.pccAvailabilityBefore ?? "Unavailable")
                LabeledContent("PCC availability after", value: record.pccAvailabilityAfter ?? "Unavailable")
                LabeledContent("Quota reset", value: record.quotaResetDate?.formatted(date: .complete, time: .shortened) ?? "Not provided")
                if let value = record.firstApproachingObservationNumber { LabeledContent("First approaching observation", value: "#\(value) today") }
                if let value = record.firstLimitReachedObservationNumber { LabeledContent("First limit reached observation", value: "#\(value) today") }
            }
            if let errorType = record.errorType {
                Section("Error") {
                    LabeledContent("Type", value: errorType)
                    Text(record.errorDescription ?? "No error details").textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Request #\(record.dailyRequestNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func metric(_ title: String, _ value: Int?) -> some View {
        LabeledContent(title, value: value.map { $0.formatted() } ?? "Unavailable")
    }
    private var imageDimensions: String {
        guard let width = record.imageWidth, let height = record.imageHeight else { return "Unavailable" }
        return "\(width) × \(height)"
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case success = "Success"
    case failed = "Failed"
    case quota = "Quota"
    case rateLimited = "Rate Limited"
    case contextLimit = "Context Limit"
    var id: String { rawValue }

    func includes(_ record: PCCRequestLog) -> Bool {
        if self == .all { return true }
        if self == .success { return record.succeeded }
        if self == .failed { return !record.succeeded && record.errorType != "Request pending" }
        guard let type = record.errorType?.lowercased(), type != "request pending" else { return false }
        switch self {
        case .all, .success, .failed: return false
        case .quota: return type.contains("quota")
        case .rateLimited: return type.contains("rate limit") || type.contains("rate-limited")
        case .contextLimit: return type.contains("context")
        }
    }
}

struct QuotaHistoryView: View {
    @Query(sort: \PCCQuotaObservation.timestamp, order: .reverse) private var observations: [PCCQuotaObservation]

    var body: some View {
        List {
            Section("Observed quota state changes") {
                if observations.isEmpty {
                    Text("No quota state transitions have been recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(observations) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.status).font(.headline)
                            Text(item.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("Today #\(item.dailyRequestNumber)")
                            Text(item.resetDate?.formatted(date: .abbreviated, time: .shortened) ?? "Reset not provided")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("Entries are saved only when the observed categorical quota state changes. No numeric Apple quota is inferred.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Quota History")
    }
}

struct DailyStatisticsView: View {
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var records: [PCCRequestLog]
    @Query(sort: \PCCQuotaObservation.timestamp, order: .reverse) private var observations: [PCCQuotaObservation]
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

    private var dayRecords: [PCCRequestLog] { records.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDay) } }
    private var dayQuota: String? {
        observations.first { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDay) }?.status
            ?? dayRecords.first?.quotaStatusAfter ?? dayRecords.first?.quotaStatusBefore
    }

    var body: some View {
        List {
            Section("Selected day") {
                HStack {
                    Button { selectedDay = Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(selectedDay.formatted(date: .complete, time: .omitted)).font(.headline)
                    Spacer()
                    Button { selectedDay = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay } label: { Image(systemName: "chevron.right") }
                        .disabled(Calendar.current.isDateInToday(selectedDay) || selectedDay > .now)
                }
                LabeledContent("Requests attempted", value: "\(dayRecords.count)")
                LabeledContent("Successful", value: "\(dayRecords.filter(\.succeeded).count)")
                LabeledContent("Failed", value: "\(dayRecords.filter { !$0.succeeded && $0.errorType != "Request pending" }.count)")
                metric("Input tokens", sum(\.inputTokens))
                metric("Cached tokens", sum(\.cachedInputTokens))
                metric("Output tokens", sum(\.outputTokens))
                metric("Reasoning tokens", sum(\.reasoningTokens))
                metric("Total tokens", sum(\.totalTokens))
                let latencies = dayRecords.compactMap(\.latencyMilliseconds)
                LabeledContent("Average latency", value: latencies.isEmpty ? "Unavailable" : String(format: "%.2f sec", Double(latencies.reduce(0, +)) / Double(latencies.count) / 1_000))
                LabeledContent("PCC quota state", value: dayQuota ?? "Unavailable")
            }
            Section("Saved requests for this day") {
                if dayRecords.isEmpty { Text("No saved request records for this day.").foregroundStyle(.secondary) }
                ForEach(dayRecords) { record in
                    NavigationLink { RequestDetailView(record: record) } label: {
                        Text("#\(record.globalRequestNumber > 0 ? record.globalRequestNumber : record.dailyRequestNumber) · \(record.succeeded ? "Success" : record.errorType ?? "Failed")")
                    }
                }
            }
        }
        .navigationTitle("Daily Statistics")
    }

    private func sum(_ keyPath: KeyPath<PCCRequestLog, Int?>) -> Int? {
        let values = dayRecords.compactMap { $0[keyPath: keyPath] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    @ViewBuilder private func metric(_ title: String, _ value: Int?) -> some View {
        LabeledContent(title, value: value.map { $0.formatted() } ?? "Unavailable")
    }
}

struct ExperimentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var records: [PCCRequestLog]
    @State private var service = PCCService()
    @State private var prompt = "Reply with one word: apple"
    @State private var selectedReasoning: PCCReasoningChoice = .default
    @State private var maximumTokens = "512"
    @State private var sessionExperimentID = UUID()
    @State private var reasoningExperimentID = UUID()

    private var sessionRuns: [PCCRequestLog] { records.filter { $0.experimentID == sessionExperimentID } }
    private var reasoningRuns: [PCCRequestLog] { records.filter { $0.experimentID == reasoningExperimentID } }

    var body: some View {
        List {
            Section("Active PCC context") {
                LabeledContent("Availability", value: service.status)
                LabeledContent("Quota", value: service.quotaStatus)
                LabeledContent("Session usage", value: service.sessionUsage.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                LabeledContent("Context size", value: service.contextSize.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                LabeledContent("Used", value: service.contextUsagePercentage.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                if (service.contextUsagePercentage ?? 0) >= 95 {
                    Label("Critical safety threshold. Start a new session before reusing this one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.footnote)
                }
            }
            Section("Shared prompt") {
                TextEditor(text: $prompt).frame(minHeight: 90)
                TextField("Maximum response tokens", text: $maximumTokens).keyboardType(.numberPad)
                Text("Each button sends exactly one manually requested PCC generation.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("New Session vs Reuse Session") {
                HStack {
                    Button("New comparison") { sessionExperimentID = UUID() }
                    Text(sessionExperimentID.uuidString.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("Run once · Reuse Session") {
                    service.reuseCurrentSession()
                    run(kind: "Session comparison", behavior: "Reuse Session", id: sessionExperimentID)
                }
                .disabled((service.contextUsagePercentage ?? 0) >= 95 || service.isLoading)
                Button("Run once · New Session Every Request") {
                    service.startNewSession()
                    run(kind: "Session comparison", behavior: "New Session Every Request", id: sessionExperimentID)
                }
                comparisonRows(sessionRuns)
            }
            Section("Reasoning-level comparison") {
                HStack {
                    Button("New comparison") { reasoningExperimentID = UUID() }
                    Text(reasoningExperimentID.uuidString.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Picker("Reasoning level", selection: $selectedReasoning) {
                    ForEach(PCCReasoningChoice.allCases) { Text($0.label).tag($0) }
                }
                Button("Run once · \(selectedReasoning.label)") {
                    run(kind: "Reasoning comparison", behavior: "Reuse Session", id: reasoningExperimentID)
                }
                .disabled((service.contextUsagePercentage ?? 0) >= 95 || service.isLoading)
                Button("Start a new session for reasoning comparison") { service.startNewSession() }
                    .disabled(service.isLoading)
                comparisonRows(reasoningRuns)
            }
            if service.isLoading {
                Section { Label("PCC request in progress", systemImage: "hourglass") }
            }
        }
        .navigationTitle("PCC Experiments")
        .task { await service.checkAvailability(modelContext: modelContext) }
    }

    private func run(kind: String, behavior: String, id: UUID) {
        guard let maxTokens = Int(maximumTokens), maxTokens > 0, !service.isLoading else { return }
        Task {
            if behavior == "Reuse Session" { service.reuseCurrentSession() }
            await service.send(prompt: prompt, reasoningLevel: selectedReasoning, maximumResponseTokens: maxTokens,
                               modelContext: modelContext, experimentID: id, experimentKind: kind, sessionBehavior: behavior)
        }
    }

    @ViewBuilder private func comparisonRows(_ rows: [PCCRequestLog]) -> some View {
        if rows.isEmpty {
            Text("No runs in this comparison yet.").font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(rows.reversed()) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.sessionBehavior ?? row.reasoningLevel ?? "Run") · \(row.succeeded ? "Success" : row.errorType ?? "Failed")").font(.subheadline.bold())
                    Text("In \(row.inputTokens.map(String.init) ?? "—") · cached \(row.cachedInputTokens.map(String.init) ?? "—") · out \(row.outputTokens.map(String.init) ?? "—") · reasoning \(row.reasoningTokens.map(String.init) ?? "—") · total \(row.totalTokens.map(String.init) ?? "—")")
                    Text("\(row.latencyMilliseconds.map { String(format: "%.2f sec", Double($0) / 1_000) } ?? "latency unavailable") · session \(row.sessionAccumulatedTokens.map { $0.formatted() } ?? "unavailable") tokens · \(row.reasoningLevel ?? "Default")")
                }
                .font(.caption).textSelection(.enabled)
            }
        }
    }
}

struct ImageTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PCCRequestLog.timestamp, order: .reverse) private var requests: [PCCRequestLog]
    @State private var service = PCCService()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var originalData: Data?
    @State private var selectionError: String?
    @State private var imagePrompt = PCCImagePrompt.describe.prompt
    @State private var resolution: PCCImageResolution = .original
    @State private var maximumTokens = "512"

    private var latestImageRequest: PCCRequestLog? { requests.first { $0.containsImage } }
    private var contextBefore: Int? { latestImageRequest?.contextUsageBefore }
    private var contextAfter: Int? { latestImageRequest?.contextUsageAfter }
    private var contextDelta: Int? { latestImageRequest?.observedContextIncrease }

    var body: some View {
        List {
            Section("PCC image input") {
                LabeledContent("Model", value: "PrivateCloudComputeLanguageModel")
                LabeledContent("PCC availability", value: service.status)
                LabeledContent("Quota", value: service.quotaStatus)
                LabeledContent("Session ID", value: String(service.sessionID.uuidString.prefix(8)))
                Text("This test sends a Foundation Models image attachment directly to the PCC-backed LanguageModelSession. No OCR, Vision, text conversion, or model fallback is used.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Select one photo") {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    Label("Choose Image from Photos", systemImage: "photo")
                }
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable().scaledToFit().frame(maxHeight: 250).clipShape(RoundedRectangle(cornerRadius: 12))
                    LabeledContent("Selected dimensions", value: "\(Int(selectedImage.size.width * selectedImage.scale)) × \(Int(selectedImage.size.height * selectedImage.scale))")
                    LabeledContent("Selected bytes", value: originalData.map { $0.count.formatted() } ?? "Unavailable")
                } else {
                    Text("Select an image from the Simulator photo library. Camera access is not used.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let selectionError { Text(selectionError).foregroundStyle(.red).font(.footnote) }
            }
            Section("Image size") {
                Picker("Attachment resolution", selection: $resolution) {
                    ForEach(PCCImageResolution.allCases) { Text($0.label).tag($0) }
                }
                Text("Medium and Small preserve aspect ratio and resize the image before attaching it. The selected choice is sent only when you tap Send.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Prompt") {
                Picker("Test", selection: $imagePrompt) {
                    ForEach(PCCImagePrompt.allCases) { Text($0.label).tag($0.prompt) }
                }
                Text(imagePrompt).font(.callout).textSelection(.enabled)
                TextField("Maximum response tokens", text: $maximumTokens).keyboardType(.numberPad)
                Button {
                    sendSelectedImage()
                } label: {
                    HStack {
                        if service.isLoading { ProgressView() }
                        Text(service.isLoading ? "Sending image to PCC…" : "Send Image Prompt to PCC")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedImage?.cgImage == nil || service.isLoading || service.isSessionResponding || Int(maximumTokens).map { $0 <= 0 } != false)
                Button("Start New PCC Session") { service.startNewSession() }
                    .disabled(service.isLoading)
            }
            Section("IMAGE TOKEN EXPERIMENT") {
                LabeledContent("Context before", value: contextBefore.map { "\($0.formatted()) tokens" } ?? "Unavailable until a request is sent")
                LabeledContent("Context after", value: contextAfter.map { "\($0.formatted()) tokens" } ?? "Unavailable until a request is sent")
                LabeledContent("Observed context increase", value: contextDelta.map { "\($0.formatted()) tokens" } ?? "Unavailable until a request is sent")
                LabeledContent("Image", value: latestImageRequest.flatMap { dimensions($0) } ?? selectedDimensions)
                LabeledContent("Request total", value: latestImageRequest?.totalTokens.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                if latestImageRequest != nil {
                    Text("Observed context increase is the measured session usage change; it is not an image-specific token count.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Latest PCC response") {
                if let response = service.response { Text(response).textSelection(.enabled) }
                else if let errorMessage = service.errorMessage {
                    Label(service.errorType ?? "Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Text(errorMessage).textSelection(.enabled)
                } else { Text("No image request sent in this session.").foregroundStyle(.secondary) }
                if let duration = service.duration { LabeledContent("Latency", value: String(format: "%.2f sec", duration)) }
            }
            if let latestImageRequest {
                Section("Latest saved image request") {
                    NavigationLink("Request #\(latestImageRequest.globalRequestNumber > 0 ? latestImageRequest.globalRequestNumber : latestImageRequest.dailyRequestNumber)") {
                        RequestDetailView(record: latestImageRequest)
                    }
                }
            }
        }
        .navigationTitle("Image Test")
        .task { await service.checkAvailability(modelContext: modelContext) }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                do {
                    let bytes = try await photo.loadTransferable(type: Data.self)
                    guard let bytes, let decoded = UIImage(data: bytes) else {
                        selectionError = "The selected photo could not be decoded as an image."
                        selectedImage = nil
                        originalData = nil
                        return
                    }
                    originalData = bytes
                    selectedImage = decoded
                    selectionError = nil
                } catch {
                    selectionError = error.localizedDescription
                    selectedImage = nil
                    originalData = nil
                }
            }
        }
    }

    private var selectedDimensions: String {
        guard let selectedImage, let cgImage = selectedImage.cgImage else { return "Unavailable" }
        return "\(cgImage.width) × \(cgImage.height)"
    }

    private func dimensions(_ record: PCCRequestLog) -> String? {
        guard let width = record.imageWidth, let height = record.imageHeight else { return nil }
        return "\(width) × \(height)"
    }

    private func sendSelectedImage() {
        guard let selectedImage, let sourceCGImage = selectedImage.cgImage,
              let originalData, let maximumResponseTokens = Int(maximumTokens), maximumResponseTokens > 0 else { return }
        let prepared: (cgImage: CGImage, orientation: CGImagePropertyOrientation, bytes: Int)
        switch resolution {
        case .original:
            prepared = (sourceCGImage, cgOrientation(selectedImage.imageOrientation), originalData.count)
        case .medium, .small:
            let cap: CGFloat = resolution == .medium ? 1_600 : 768
            let ratio = min(1, cap / max(selectedImage.size.width, selectedImage.size.height))
            let size = CGSize(width: max(1, floor(selectedImage.size.width * ratio)), height: max(1, floor(selectedImage.size.height * ratio)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { _ in selectedImage.draw(in: CGRect(origin: .zero, size: size)) }
            guard let cgImage = resized.cgImage, let encoded = resized.jpegData(compressionQuality: 0.84) else {
                selectionError = "The selected image could not be resized for attachment."
                return
            }
            prepared = (cgImage, .up, encoded.count)
        }
        Task {
            await service.sendImage(prompt: imagePrompt, image: prepared.cgImage, orientation: prepared.orientation,
                                    imageApproximateBytes: prepared.bytes, imageResolution: resolution.label,
                                    maximumResponseTokens: maximumResponseTokens, modelContext: modelContext)
        }
    }

    private func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        case .left: .left
        @unknown default: .up
        }
    }
}

private enum PCCImagePrompt: String, CaseIterable, Identifiable {
    case describe
    case mostImportant
    case readableText

    var id: String { rawValue }
    var label: String {
        switch self {
        case .describe: "Describe the image"
        case .mostImportant: "Most important detail"
        case .readableText: "Readable text and summary"
        }
    }
    var prompt: String {
        switch self {
        case .describe: "Describe what you see in this image. Identify the main objects, setting, colors, and any notable details."
        case .mostImportant: "What is the most important thing visible in this image, and why?"
        case .readableText: "Read any clearly visible text in this image and summarize what the image is about."
        }
    }
}

private enum PCCImageResolution: String, CaseIterable, Identifiable {
    case original
    case medium
    case small

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
