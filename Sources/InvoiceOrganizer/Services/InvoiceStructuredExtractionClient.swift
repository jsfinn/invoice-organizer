import Foundation

enum InvoiceStructuredExtractionClientError: LocalizedError, Sendable {
    case misconfigured(String)
    case unavailable(String)
    case authenticationFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .misconfigured(message),
             let .unavailable(message),
             let .authenticationFailed(message),
             let .invalidResponse(message):
            return message
        }
    }

    var preflightStatus: LLMPreflightStatus {
        switch self {
        case let .misconfigured(message):
            return LLMPreflightStatus(state: .misconfigured, message: message)
        case let .unavailable(message):
            return LLMPreflightStatus(state: .unavailable, message: message)
        case let .authenticationFailed(message):
            return LLMPreflightStatus(state: .authenticationFailed, message: message)
        case let .invalidResponse(message):
            return LLMPreflightStatus(state: .misconfigured, message: message)
        }
    }
}

protocol InvoiceStructuredExtractionClient: Sendable {
    func preflightCheck(settings: LLMSettings) async -> LLMPreflightStatus
    func extractStructuredData(from text: String, settings: LLMSettings) async throws -> InvoiceStructuredDataRecord?
}

protocol StructuredExtractionTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionStructuredExtractionTransport: StructuredExtractionTransporting {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InvoiceStructuredExtractionClientError.invalidResponse("The LLM provider returned a non-HTTP response.")
        }

        return (data, httpResponse)
    }
}

struct RoutedStructuredExtractionClient: InvoiceStructuredExtractionClient {
    private let lmStudioClient: LMStudioStructuredExtractionClient
    private let openAIClient: OpenAIStructuredExtractionClient

    init(
        lmStudioClient: LMStudioStructuredExtractionClient = LMStudioStructuredExtractionClient(),
        openAIClient: OpenAIStructuredExtractionClient = OpenAIStructuredExtractionClient()
    ) {
        self.lmStudioClient = lmStudioClient
        self.openAIClient = openAIClient
    }

    func preflightCheck(settings: LLMSettings) async -> LLMPreflightStatus {
        switch settings.provider {
        case .lmStudio:
            return await lmStudioClient.preflightCheck(settings: settings)
        case .openAI:
            return await openAIClient.preflightCheck(settings: settings)
        }
    }

    func extractStructuredData(from text: String, settings: LLMSettings) async throws -> InvoiceStructuredDataRecord? {
        switch settings.provider {
        case .lmStudio:
            return try await lmStudioClient.extractStructuredData(from: text, settings: settings)
        case .openAI:
            return try await openAIClient.extractStructuredData(from: text, settings: settings)
        }
    }
}

struct LMStudioStructuredExtractionClient: InvoiceStructuredExtractionClient {
    private let transport: any StructuredExtractionTransporting

    init(transport: any StructuredExtractionTransporting = URLSessionStructuredExtractionTransport()) {
        self.transport = transport
    }

    func preflightCheck(settings: LLMSettings) async -> LLMPreflightStatus {
        do {
            let request = try buildModelsRequest(settings: settings, authorizationToken: "lm-studio")
            let (_, response) = try await transport.send(request)

            guard (200..<300).contains(response.statusCode) else {
                return LLMPreflightStatus(
                    state: .unavailable,
                    message: "LM Studio is configured but did not respond successfully. Open LM Studio, load a model, and start the local server."
                )
            }

            return LLMPreflightStatus(
                state: .ready,
                message: "LM Studio is reachable."
            )
        } catch let error as InvoiceStructuredExtractionClientError {
            return error.preflightStatus
        } catch {
            return LLMPreflightStatus(
                state: .unavailable,
                message: "LM Studio is unreachable. Open LM Studio, load a model, and start the local server."
            )
        }
    }

    func extractStructuredData(from text: String, settings: LLMSettings) async throws -> InvoiceStructuredDataRecord? {
        let request = try buildChatCompletionsRequest(
            text: text,
            settings: settings,
            authorizationToken: "lm-studio"
        )
        let (data, response) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            throw InvoiceStructuredExtractionClientError.unavailable(
                "LM Studio is configured but unavailable. Open LM Studio, load a model, and start the local server."
            )
        }

        return try parseStructuredRecord(from: data, provider: .lmStudio, modelName: settings.modelName)
    }
}

struct OpenAIStructuredExtractionClient: InvoiceStructuredExtractionClient {
    private let transport: any StructuredExtractionTransporting

    init(transport: any StructuredExtractionTransporting = URLSessionStructuredExtractionTransport()) {
        self.transport = transport
    }

    func preflightCheck(settings: LLMSettings) async -> LLMPreflightStatus {
        do {
            let request = try buildModelsRequest(settings: settings, authorizationToken: settings.apiKey)
            let (_, response) = try await transport.send(request)

            if response.statusCode == 401 {
                return LLMPreflightStatus(
                    state: .authenticationFailed,
                    message: "The OpenAI API key was rejected."
                )
            }

            guard (200..<300).contains(response.statusCode) else {
                return LLMPreflightStatus(
                    state: .unavailable,
                    message: "OpenAI is configured but unavailable right now."
                )
            }

            return LLMPreflightStatus(
                state: .ready,
                message: "OpenAI is reachable."
            )
        } catch let error as InvoiceStructuredExtractionClientError {
            return error.preflightStatus
        } catch {
            return LLMPreflightStatus(
                state: .unavailable,
                message: "OpenAI is unreachable right now."
            )
        }
    }

    func extractStructuredData(from text: String, settings: LLMSettings) async throws -> InvoiceStructuredDataRecord? {
        let request = try buildChatCompletionsRequest(
            text: text,
            settings: settings,
            authorizationToken: settings.apiKey
        )
        let (data, response) = try await transport.send(request)

        if response.statusCode == 401 {
            throw InvoiceStructuredExtractionClientError.authenticationFailed("The OpenAI API key was rejected.")
        }

        guard (200..<300).contains(response.statusCode) else {
            throw InvoiceStructuredExtractionClientError.unavailable("OpenAI is configured but unavailable right now.")
        }

        return try parseStructuredRecord(from: data, provider: .openAI, modelName: settings.modelName)
    }
}

private func buildModelsRequest(settings: LLMSettings, authorizationToken: String) throws -> URLRequest {
    let baseURL = try normalizedBaseURL(from: settings.baseURL)
    var request = URLRequest(url: baseURL.appendingPathComponent("models"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if !authorizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }

    return request
}

private func buildChatCompletionsRequest(text: String, settings: LLMSettings, authorizationToken: String) throws -> URLRequest {
    let trimmedModel = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
        throw InvoiceStructuredExtractionClientError.misconfigured("Choose an LLM model name before running structured extraction.")
    }

    let baseURL = try normalizedBaseURL(from: settings.baseURL)
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if !authorizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }

    let customInstructions = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentDate = structuredExtractionPromptDateString()
    let userPrompt = """
    Extract the following fields from this invoice, receipt, or document text:
    - companyName
    - invoiceNumber
    - invoiceDate
    - documentType

    Today's date is \(currentDate).

    Invoice text:
    \(text)
    """
    var messages: [[String: String]] = [
        [
            "role": "system",
            "content": "You extract structured invoice or receipt fields from OCR or PDF text. Return valid JSON only. If a field is unknown or not present, return an empty string. Receipts may not have an invoiceNumber. documentType must be either 'invoice', 'receipt', or an empty string. invoiceDate must be in YYYY-MM-DD format. companyName should be normalized to a plain vendor name with no special characters. Use the provided current date as temporal context when interpreting relative or ambiguous dates."
        ]
    ]

    messages.append([
        "role": "user",
        "content": userPrompt
    ])

    if !customInstructions.isEmpty {
        messages.append([
            "role": "user",
            "content": """
            Additional user-specific extraction guidance:
            \(customInstructions)
            """
        ])
    }

    let payload: [String: Any] = [
        "model": trimmedModel,
        "temperature": 0,
        "stream": false,
        "messages": messages,
        "response_format": [
            "type": "json_schema",
            "json_schema": [
                "name": "invoice_structured_data",
                "schema": [
                    "type": "object",
                    "properties": [
                        "companyName": ["type": "string"],
                        "invoiceNumber": ["type": "string"],
                        "invoiceDate": ["type": "string"],
                        "documentType": ["type": "string"],
                    ],
                    "required": ["companyName", "invoiceNumber", "invoiceDate", "documentType"],
                    "additionalProperties": false,
                ],
            ],
        ],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    return request
}

private func structuredExtractionPromptDateString(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: now)
}

private func normalizedBaseURL(from baseURL: String) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw InvoiceStructuredExtractionClientError.misconfigured("Choose an LLM server URL before running structured extraction.")
    }

    guard let url = URL(string: trimmed) else {
        throw InvoiceStructuredExtractionClientError.misconfigured("The configured LLM server URL is invalid.")
    }

    return url.path.hasSuffix("/v1") ? url : url.appendingPathComponent("v1")
}

private func parseStructuredRecord(from data: Data, provider: LLMProvider, modelName: String) throws -> InvoiceStructuredDataRecord? {
    let response = try JSONDecoder().decode(OpenAICompatibleChatCompletionResponse.self, from: data)
    guard let content = response.choices.first?.message.content else {
        throw InvoiceStructuredExtractionClientError.invalidResponse("The LLM provider returned an empty completion.")
    }

    let normalizedPayload = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let payloadData = normalizedPayload.data(using: .utf8) else {
        throw InvoiceStructuredExtractionClientError.invalidResponse("The LLM provider returned unreadable structured data.")
    }

    let rawFields = try JSONDecoder().decode(RawStructuredFields.self, from: payloadData)
    let record = InvoiceStructuredDataRecord(
        companyName: normalizeVendorName(rawFields.companyName),
        invoiceNumber: normalizeField(rawFields.invoiceNumber),
        invoiceDate: parseInvoiceDate(rawFields.invoiceDate),
        documentType: parseDocumentType(rawFields.documentType),
        provider: provider,
        modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    return record.hasAnyValue ? record : nil
}

private func normalizeField(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }

    return trimmed
}

private func normalizeVendorName(_ value: String?) -> String? {
    guard let normalized = normalizeField(value) else { return nil }

    let collapsedWhitespace = normalized.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    let shouldTitleCaseNonSuffixTokens =
        collapsedWhitespace.rangeOfCharacter(from: .lowercaseLetters) == nil &&
        collapsedWhitespace.rangeOfCharacter(from: .uppercaseLetters) != nil

    return collapsedWhitespace
        .split(separator: " ", omittingEmptySubsequences: true)
        .map { normalizeVendorToken(String($0), shouldTitleCase: shouldTitleCaseNonSuffixTokens) }
        .joined(separator: " ")
}

private func normalizeVendorToken(_ token: String, shouldTitleCase: Bool) -> String {
    let uppercaseToken = token.uppercased()
    if let canonicalToken = canonicalVendorTokens[uppercaseToken] {
        return canonicalToken
    }

    guard shouldTitleCase else {
        return token
    }

    var normalized = ""
    var shouldUppercaseNextLetter = true

    for character in token.lowercased() {
        if shouldUppercaseNextLetter {
            normalized.append(String(character).uppercased())
        } else {
            normalized.append(character)
        }

        shouldUppercaseNextLetter = vendorWordBreakCharacters.contains(character)
    }

    return normalized
}

private func parseInvoiceDate(_ rawValue: String?) -> Date? {
    guard let normalizedValue = normalizeField(rawValue) else { return nil }

    let dateParsers: [(String) -> Date?] = [
        parseISODateOnly,
        parseSlashDateOnly
    ]

    return dateParsers.compactMap { $0(normalizedValue) }.first
}

private func parseISODateOnly(_ value: String) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]) else {
        return nil
    }

    return makeLocalCalendarDate(year: year, month: month, day: day)
}

private func parseSlashDateOnly(_ value: String) -> Date? {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let month = Int(parts[0]),
          let day = Int(parts[1]),
          let year = Int(parts[2]) else {
        return nil
    }

    return makeLocalCalendarDate(year: year, month: month, day: day)
}

private func makeLocalCalendarDate(year: Int, month: Int, day: Int) -> Date? {
    var localCalendar = Calendar(identifier: .gregorian)
    localCalendar.timeZone = .autoupdatingCurrent

    return localCalendar.date(from: DateComponents(
        calendar: localCalendar,
        timeZone: localCalendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: 12
    ))
}

private func parseDocumentType(_ rawValue: String?) -> DocumentType? {
    guard let normalizedValue = normalizeField(rawValue)?.lowercased() else { return nil }

    switch normalizedValue {
    case "invoice":
        return .invoice
    case "receipt":
        return .receipt
    default:
        return nil
    }
}

private let canonicalVendorTokens: [String: String] = [
    "LLC": "LLC",
    "L.L.C.": "LLC",
    "LLP": "LLP",
    "L.L.P.": "LLP",
    "LP": "LP",
    "L.P.": "LP",
    "INC": "Inc",
    "INC.": "Inc",
    "LTD": "Ltd",
    "LTD.": "Ltd",
    "CORP": "Corp",
    "CORP.": "Corp",
    "CO": "Co",
    "CO.": "Co",
    "USA": "USA",
    "U.S.A.": "USA",
    "US": "US",
    "U.S.": "US",
    "N.A.": "N.A."
]

private let vendorWordBreakCharacters: Set<Character> = ["-", "/", "&", "'", "(", "["]

private struct OpenAICompatibleChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct RawStructuredFields: Decodable {
    let companyName: String
    let invoiceNumber: String
    let invoiceDate: String
    let documentType: String?
}
