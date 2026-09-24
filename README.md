# PCC Test

A minimal SwiftUI app for sending text prompts directly to Apple's `PrivateCloudComputeLanguageModel`. It never falls back to `SystemLanguageModel` or another model.

## Requirements and configuration

- Xcode 27.0 SDK; the PCC API in this SDK is marked iOS 27.0+.
- An iOS 27 Simulator runtime for a runtime request attempt.
- `FoundationModels.framework` is imported and linked by the Xcode target.
- The app target points to `PCCTest.entitlements`, which declares `com.apple.developer.private-cloud-compute = true`.
- Apple describes this as a managed entitlement and requires eligibility and access approval. Adding the key to this project does not mean Apple has granted it. Request access through Apple's [Accessing Private Cloud Compute](https://developer.apple.com/documentation/foundationmodels/accessing-private-cloud-compute) process and use a provisioning profile that includes it.

The local Simulator build currently uses Xcode's “Sign to Run Locally” identity. Xcode filtered the managed PCC entitlement out of that signature (the signed app entitlement dictionary is empty), so the entitlement is declared in the project but is not active in this build. The Simulator request below nevertheless returned a response from the explicitly selected PCC model. To test with an active signed entitlement, add a development team with Apple's PCC entitlement approval and use the matching provisioning profile.

The app shows the exact PCC availability state and quota state exposed by the SDK. Request failures display Foundation Models/PCC error details. Availability states such as `deviceNotEligible` and `systemNotReady` are shown directly; they can include Simulator eligibility, Apple Intelligence readiness, or service state and are not silently reclassified.

For repeatable Simulator checks without tapping the UI, launch the app with `--pcc-test-prompt=...`. The prompt is sent through the same PCC service used by the button.

## Run

Open `PCCTest.xcodeproj`, select an iOS 27 Simulator, and run the `PCCTest` scheme. The app logs PCC checks and request outcomes to the Xcode console without logging prompt or response content.
