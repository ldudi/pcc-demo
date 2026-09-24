# PCC Limits Lab

A small iOS 27 SwiftUI app for measuring real requests to Apple's `PrivateCloudComputeLanguageModel`. It never falls back to `SystemLanguageModel` or another model. Request prompts, responses, exact Foundation Models usage, quota observations, errors, and timings are saved locally with SwiftData. No analytics or backend is used.

## Runtime facts

- `PrivateCloudComputeLanguageModel.contextSize` and `quotaUsage` are read from the installed framework at runtime.
- Response and session usage are recorded from `response.usage` and `session.usage`.
- The installed iOS 27 SDK does not expose `tokenCount(for:)` on `PrivateCloudComputeLanguageModel`; exact preflight prompt tokens are shown as unavailable. The post-response usage API is used instead.
- Apple's PCC quota API reports a category and optional reset date/suggestion. It does not expose an exact remaining request count or a universal daily allowance.
- The locally configured context warnings at 70%, 85%, and 95% are app safety thresholds, not Apple limits. Reaching 95% blocks PCC generation until a new session is started.
- Context size, daily PCC quota, and short-term `LanguageModelError.rateLimited` are separate measurements.

## Project and entitlement

The project links `FoundationModels.framework`, targets iOS 27, and declares `com.apple.developer.private-cloud-compute = true` in `PCCTest.entitlements`. Apple treats PCC access as a managed entitlement requiring approval. The current local Simulator signature filters that entitlement out; successful Simulator requests were still observed, but a signed approved entitlement needs an Apple-approved development team and matching provisioning profile. See Apple's [PCC entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute).

## Run

Open `PCCTest.xcodeproj`, select the `PCCTest` scheme and an iOS 27 Simulator, then run. The `Lab`, `History`, and `Usage` tabs show the current session, saved attempts, historical aggregates, quota observations, and export controls. `New Session` creates a fresh PCC session while keeping all saved history.

For deliberate Simulator verification, pass one `--pcc-test-prompt=...` argument per prompt at launch. Multiple arguments run sequentially in the same PCC session, one generation at a time, and save each result.
