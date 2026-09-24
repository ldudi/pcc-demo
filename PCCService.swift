import Foundation
import FoundationModels
import Observation

@Observable
@MainActor
final class PCCService {
    private(set) var status = "Checking…"
    private(set) var availabilityDetail: String?
    private(set) var quotaStatus = "Unknown"
    private(set) var response: String?
    private(set) var errorMessage: String?
    private(set) var duration: TimeInterval?
    private(set) var isLoading = false
    private(set) var requestState = "Not sent"

    @available(iOS 27.0, *)
    private var model: PrivateCloudComputeLanguageModel { PrivateCloudComputeLanguageModel() }

    func checkAvailability() async {
        print("[PCC] Checking availability")
        guard #available(iOS 27.0, *) else {
            status = "Unavailable"
            availabilityDetail = "PrivateCloudComputeLanguageModel requires iOS 27.0 or later."
            quotaStatus = "Unavailable"
            print("[PCC] API unavailable: requires iOS 27.0 or later")
            return
        }

        switch model.availability {
        case .available:
            status = "Available"
            availabilityDetail = nil
            print("[PCC] PCC available")
        case .unavailable(let reason):
            status = "Unavailable"
            availabilityDetail = reasonDescription(reason)
            print("[PCC] PCC unavailable: \(availabilityDetail ?? String(describing: reason))")
        @unknown default:
            status = "Unknown"
            availabilityDetail = "The SDK returned an unrecognized availability state."
            print("[PCC] PCC availability is an unknown future value")
        }

        let quota = model.quotaUsage
        quotaStatus = quotaDescription(quota)
        print("[PCC] Quota status: \(quotaStatus)")
    }

    func send(prompt: String) async {
        guard !isLoading else { return }
        response = nil
        errorMessage = nil
        duration = nil
        isLoading = true
        requestState = "In progress"
        defer { isLoading = false }

        guard #available(iOS 27.0, *) else {
            fail("PrivateCloudComputeLanguageModel requires iOS 27.0 or later.")
            return
        }

        if model.availability != .available {
            let detail: String
            if case .unavailable(let reason) = model.availability {
                detail = reasonDescription(reason)
            } else {
                detail = "PCC availability is unknown."
            }
            status = "Unavailable"
            availabilityDetail = detail
            fail("PCC is unavailable: \(detail)")
            return
        }

        print("[PCC] Creating PrivateCloudComputeLanguageModel")
        let pccModel = model
        print("[PCC] Creating LanguageModelSession")
        let session = LanguageModelSession(model: pccModel)
        print("[PCC] Sending request")
        let start = ContinuousClock.now
        do {
            let result = try await session.respond(to: prompt)
            let elapsed = start.duration(to: .now)
            let components = elapsed.components
            duration = Double(components.seconds) + Double(components.attoseconds) / 1e18
            response = result.content
            requestState = "Successful"
            errorMessage = nil
            print("[PCC] Response received")
            print(String(format: "[PCC] Duration: %.2f seconds", duration ?? 0))
            await checkAvailability()
        } catch {
            let elapsed = start.duration(to: .now)
            let components = elapsed.components
            duration = Double(components.seconds) + Double(components.attoseconds) / 1e18
            fail(describe(error))
            if case PrivateCloudComputeLanguageModel.Error.quotaLimitReached = error {
                quotaStatus = "Limit reached"
            }
        }
    }

    @available(iOS 27.0, *)
    private func quotaDescription(_ quota: PrivateCloudComputeLanguageModel.QuotaUsage) -> String {
        let base: String
        switch quota.status {
        case .belowLimit(let below):
            base = below.isApproachingLimit ? "Below limit, approaching" : "Below limit"
        case .limitReached:
            base = "Limit reached"
        @unknown default:
            base = "Unknown quota state"
        }
        if let resetDate = quota.resetDate {
            return "\(base); resets \(resetDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return base
    }

    @available(iOS 27.0, *)
    private func reasonDescription(_ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device or Simulator configuration is not eligible for PCC."
        case .systemNotReady: "Apple Intelligence or the PCC system service is not ready."
        @unknown default: "The SDK returned an unrecognized unavailable reason: \(String(describing: reason))"
        }
    }

    private func describe(_ error: Error) -> String {
        if #available(iOS 27.0, *), let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            switch pccError {
            case .networkFailure(let detail): return "PCC network failure: \(detail.debugDescription)"
            case .quotaLimitReached(let detail):
                let reset = detail.resetDate.map { " Reset: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                return "PCC quota limit reached.\(reset) \(detail.debugDescription)"
            case .serviceUnavailable(let detail): return "PCC service unavailable: \(detail.debugDescription)"
            @unknown default: return "PCC error: \(pccError.localizedDescription) (\(String(reflecting: type(of: error))))"
            }
        }
        return "\(error.localizedDescription) (\(String(reflecting: type(of: error))))"
    }

    private func fail(_ message: String) {
        response = nil
        errorMessage = message
        requestState = "Failed"
        print("[PCC] REQUEST FAILED")
        print("[PCC] Error type: \(message.components(separatedBy: ":").first ?? "FoundationModels error")")
        print("[PCC] Error: \(message)")
    }
}
