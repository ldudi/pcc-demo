import SwiftUI

struct ContentView: View {
    @State private var service = PCCService()
    @State private var prompt = "Explain in three sentences why the sky appears blue."

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Cloud Compute") {
                    LabeledContent("Status", value: service.status)
                    if let availabilityDetail = service.availabilityDetail {
                        Text(availabilityDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Prompt")

                    Button {
                        Task { await service.send(prompt: prompt) }
                    } label: {
                        HStack {
                            if service.isLoading { ProgressView() }
                            Text(service.isLoading ? "Contacting Private Cloud Compute…" : "Send to PCC")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(service.isLoading || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Response") {
                    if let response = service.response {
                        Text(response)
                            .textSelection(.enabled)
                    } else if let error = service.errorMessage {
                        Label("Request Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .textSelection(.enabled)
                    } else {
                        Text("No request sent yet.")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Model", value: "Private Cloud Compute")
                    LabeledContent("Request", value: service.requestState)
                    if let duration = service.duration {
                        LabeledContent("Duration", value: String(format: "%.2f seconds", duration))
                    }
                }

                Section {
                    DisclosureGroup("Diagnostics") {
                        LabeledContent("PCC availability", value: service.status)
                        LabeledContent("Quota status", value: service.quotaStatus)
                        LabeledContent("Model", value: "PrivateCloudComputeLanguageModel")
                        LabeledContent("Request state", value: service.requestState)
                        LabeledContent("Last request duration", value: service.duration.map { String(format: "%.2f seconds", $0) } ?? "—")
                        LabeledContent("Last error", value: service.errorMessage ?? "—")
                        Text("Full diagnostics are also written to the Xcode console. Prompt and response text are not logged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("PCC Test")
            .task {
                await service.checkAvailability()
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pcc-test-prompt=") }) {
                    let testPrompt = String(argument.dropFirst("--pcc-test-prompt=".count))
                    prompt = testPrompt
                    await service.send(prompt: testPrompt)
                }
            }
        }
    }
}
