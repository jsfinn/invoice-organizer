import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        TabView(selection: $selectedSection) {
            GeneralSettingsSection(model: model)
                .tabItem {
                    Label(SettingsSection.general.title, systemImage: SettingsSection.general.systemImage)
                }
                .tag(SettingsSection.general)

            LLMSettingsSection(
                model: model,
                llmProviderBinding: llmProviderBinding,
                llmBaseURLBinding: llmBaseURLBinding,
                llmModelNameBinding: llmModelNameBinding,
                openAIAPIKeyBinding: openAIAPIKeyBinding,
                customInstructionsBinding: customInstructionsBinding
            )
            .tabItem {
                Label(SettingsSection.llm.title, systemImage: SettingsSection.llm.systemImage)
            }
            .tag(SettingsSection.llm)
        }
    }

    private var llmProviderBinding: Binding<LLMProvider> {
        Binding(
            get: { model.llmSettings.provider },
            set: { model.updateLLMProvider($0) }
        )
    }

    private var llmBaseURLBinding: Binding<String> {
        Binding(
            get: { model.llmSettings.baseURL },
            set: { model.updateLLMBaseURL($0) }
        )
    }

    private var llmModelNameBinding: Binding<String> {
        Binding(
            get: { model.llmSettings.modelName },
            set: { model.updateLLMModelName($0) }
        )
    }

    private var openAIAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.llmSettings.apiKey },
            set: { model.updateOpenAIAPIKey($0) }
        )
    }

    private var customInstructionsBinding: Binding<String> {
        Binding(
            get: { model.llmSettings.customInstructions },
            set: { model.updateLLMCustomInstructions($0) }
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .llm:
            return "LLM"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .llm:
            return "sparkles"
        }
    }
}

private struct GeneralSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Folders") {
                FolderRow(
                    title: "Inbox",
                    subtitle: "Required. This is the watched folder where new invoices arrive.",
                    path: model.inboxFolderDisplayPath,
                    isRequired: true,
                    onChoose: { model.pickFolder(for: .inbox) },
                    onClear: { model.clearFolder(for: .inbox) }
                )

                FolderRow(
                    title: "Processing",
                    subtitle: "Required. Files moved to In Progress are physically relocated here until they are done.",
                    path: model.processingFolderDisplayPath,
                    isRequired: true,
                    onChoose: { model.pickFolder(for: .processing) },
                    onClear: { model.clearFolder(for: .processing) }
                )

                FolderRow(
                    title: "Processed",
                    subtitle: "Required. Completed invoices will eventually be filed under this folder.",
                    path: model.processedFolderDisplayPath,
                    isRequired: true,
                    onChoose: { model.pickFolder(for: .processed) },
                    onClear: { model.clearFolder(for: .processed) }
                )
            }

            Section("Status") {
                LabeledContent("Inbox Ready", value: model.folderSettings.inboxURL == nil ? "No" : "Yes")
                LabeledContent("Processing Ready", value: model.folderSettings.processingURL == nil ? "No" : "Yes")
                LabeledContent("Processed Ready", value: model.folderSettings.processedURL == nil ? "No" : "Yes")
                LabeledContent("Watching Folders", value: model.isWatchingFolders ? "Yes" : "No")
                LabeledContent("Invoices Loaded", value: "\(model.invoices.count)")
            }

            if let errorMessage = model.settingsErrorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LLMSettingsSection: View {
    @ObservedObject var model: AppModel
    let llmProviderBinding: Binding<LLMProvider>
    let llmBaseURLBinding: Binding<String>
    let llmModelNameBinding: Binding<String>
    let openAIAPIKeyBinding: Binding<String>
    let customInstructionsBinding: Binding<String>

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Provider", selection: llmProviderBinding) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                LLMFieldRow(
                    title: "Base URL",
                    subtitle: model.llmSettings.provider == .lmStudio
                        ? "LM Studio local server, usually http://localhost:1234/v1"
                        : "OpenAI API base URL, usually https://api.openai.com/v1",
                    text: llmBaseURLBinding,
                    prompt: "Base URL"
                )

                LLMFieldRow(
                    title: "Model",
                    subtitle: model.llmSettings.provider == .lmStudio
                        ? "The loaded LM Studio model identifier."
                        : "The OpenAI model to use for structured extraction.",
                    text: llmModelNameBinding,
                    prompt: "Model name"
                )

                if model.llmSettings.provider == .openAI {
                    SecureLLMFieldRow(
                        title: "API Key",
                        subtitle: "Required for OpenAI.",
                        text: openAIAPIKeyBinding,
                        prompt: "OpenAI API key"
                    )
                }

                MultilineLLMFieldRow(
                    title: "Custom Instructions",
                    subtitle: "Optional guidance for vendor normalization, company-specific rules, and other extraction hints.",
                    text: customInstructionsBinding,
                    prompt: """
                    Example: My company name is ABC company and our address is 123 Main St, so do not use ABC company as the vendor name. Sometimes we'll have a receipt for "Burger Joint"; when you see that, use Restaurant Depo as the vendor name.
                    """
                )
            }

            Section("Status") {
                HStack {
                    Button("Check Connection") {
                        model.checkLLMConnection()
                    }

                    Spacer()

                    Text(model.llmPreflightStatus.state == .ready ? "Ready" : "Needs Attention")
                        .foregroundStyle(model.llmPreflightStatus.state == .ready ? .green : .secondary)
                }

                LabeledContent("LLM Provider", value: model.llmSettings.provider.rawValue)
                Text(model.llmStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(model.llmPreflightStatus.state == .ready ? Color.secondary : Color.orange)

                Text(
                    model.llmSettings.provider == .lmStudio
                        ? "LM Studio must be installed, open, have a model loaded, and have its local server started."
                        : "OpenAI requires a valid API key and reachable endpoint."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = model.settingsErrorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderRow: View {
    let title: String
    let subtitle: String
    let path: String
    let isRequired: Bool
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)

                if isRequired {
                    Text("Required")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                Button("Choose Folder", action: onChoose)
                Button("Clear", role: .destructive, action: onClear)
                    .disabled(path == "Not selected")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LLMFieldRow: View {
    let title: String
    let subtitle: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 4)
    }
}

private struct SecureLLMFieldRow: View {
    let title: String
    let subtitle: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 4)
    }
}

private struct MultilineLLMFieldRow: View {
    let title: String
    let subtitle: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NativeMultilineTextView(text: text, placeholder: prompt)
                .frame(minHeight: 120)
        }
        .padding(.vertical, 4)
    }
}

private struct NativeMultilineTextView: NSViewRepresentable {
    let text: Binding<String>
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text)
    }

    func makeNSView(context: Context) -> PlaceholderTextViewContainer {
        let container = PlaceholderTextViewContainer()
        container.textView.delegate = context.coordinator
        container.textView.string = text.wrappedValue
        container.placeholderLabel.stringValue = placeholder
        container.updatePlaceholderVisibility()
        return container
    }

    func updateNSView(_ nsView: PlaceholderTextViewContainer, context: Context) {
        if nsView.textView.string != text.wrappedValue {
            nsView.textView.string = text.wrappedValue
        }
        nsView.placeholderLabel.stringValue = placeholder
        nsView.updatePlaceholderVisibility()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            (textView.enclosingScrollView?.superview as? PlaceholderTextViewContainer)?.updatePlaceholderVisibility()
        }
    }
}

private final class PlaceholderTextViewContainer: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let placeholderLabel = NonInteractivePlaceholderLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupScrollView()
        setupTextView()
        setupPlaceholder()
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
    }

    private func setupTextView() {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
    }

    private func setupPlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func layoutViews() {
        addSubview(scrollView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])
    }
}

private final class NonInteractivePlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
