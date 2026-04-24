import Foundation

enum InvoiceFileType: String, CaseIterable, Identifiable, Sendable {
    case pdf = "PDF"
    case image = "Image"
    case jpeg = "JPEG"
    case heic = "HEIC"

    var id: String { rawValue }

    var duplicatePriority: Int {
        switch self {
        case .pdf: 0
        case .jpeg, .image: 1
        case .heic: 2
        }
    }
}

enum InvoiceLocation: String, CaseIterable, Identifiable, Codable, Sendable {
    case inbox = "Inbox"
    case processing = "Processing"
    case processed = "Processed"

    var id: String { rawValue }
}

enum InvoiceQueueTab: String, CaseIterable, Identifiable, Sendable {
    case unprocessed = "Unprocessed"
    case inProgress = "In Progress"
    case processed = "Processed"

    var id: String { rawValue }
}

enum InvoiceStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case unprocessed = "Unprocessed"
    case inProgress = "In Progress"
    case processed = "Processed"
    case blockedDuplicate = "Blocked Duplicate"

    var id: String { rawValue }
}

enum DocumentType: String, CaseIterable, Identifiable, Codable, Sendable {
    case invoice = "Invoice"
    case receipt = "Receipt"

    var id: String { rawValue }
}

struct PhysicalArtifact: Identifiable, Hashable, Sendable {
    typealias ID = String

    let id: ID
    var documentID: String
    var name: String
    var fileURL: URL
    var location: InvoiceLocation
    var processedAt: Date?
    var addedAt: Date
    var modifiedAt: Date
    var fileType: InvoiceFileType
    var status: InvoiceStatus
    var contentHash: String?
    var duplicateOfPath: String?
    var duplicateReason: String?

    init(
        id: ID,
        name: String,
        fileURL: URL,
        location: InvoiceLocation,
        vendor: String? = nil,
        invoiceDate: Date? = nil,
        invoiceNumber: String? = nil,
        documentType: DocumentType? = nil,
        processedAt: Date? = nil,
        addedAt: Date,
        modifiedAt: Date? = nil,
        fileType: InvoiceFileType,
        status: InvoiceStatus,
        contentHash: String? = nil,
        duplicateOfPath: String? = nil,
        duplicateReason: String? = nil
    ) {
        self.id = id
        self.documentID = id
        self.name = name
        self.fileURL = fileURL
        self.location = location
        self.processedAt = processedAt
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt ?? addedAt
        self.fileType = fileType
        self.status = status
        self.contentHash = contentHash
        self.duplicateOfPath = duplicateOfPath
        self.duplicateReason = duplicateReason
    }

    var isDuplicate: Bool {
        status == .blockedDuplicate
    }

    var canMoveToInProgress: Bool {
        location == .inbox && status == .unprocessed
    }

    var canPreExtractText: Bool {
        location == .inbox && status == .unprocessed && contentHash != nil
    }

    var canEditWorkflowMetadata: Bool {
        location == .processing && status == .inProgress
    }

    var canMarkDone: Bool {
        location == .processing && status == .inProgress
    }

    var canReopenToInProgress: Bool {
        location == .processed && status == .processed
    }

    var canDragBetweenQueues: Bool {
        canMoveToInProgress || canMarkDone || canReopenToInProgress
    }

    var canDragToQuickBooks: Bool {
        location == .processing && status == .inProgress
    }

    static func stableID(for fileURL: URL) -> ID {
        PhysicalArtifactIdentityStore.shared.id(for: fileURL)
    }
}

enum InvoiceWorkflowMetadataScope: String, Codable, Sendable {
    case document
}

struct StoredInvoiceWorkflow: Codable, Equatable, Sendable {
    var vendor: String?
    var invoiceDate: Date?
    var invoiceNumber: String?
    var documentType: DocumentType?
    var isInProgress: Bool
    var metadataScope: InvoiceWorkflowMetadataScope?

    init(
        vendor: String?,
        invoiceDate: Date?,
        invoiceNumber: String?,
        documentType: DocumentType? = nil,
        isInProgress: Bool,
        metadataScope: InvoiceWorkflowMetadataScope? = nil
    ) {
        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.invoiceNumber = invoiceNumber
        self.documentType = documentType
        self.isInProgress = isInProgress
        self.metadataScope = metadataScope
    }
}

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case lmStudio = "LM Studio"
    case openAI = "OpenAI"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .lmStudio:
            return "http://localhost:1234/v1"
        case .openAI:
            return "https://api.openai.com/v1"
        }
    }

    var defaultModelName: String {
        switch self {
        case .lmStudio:
            return ""
        case .openAI:
            return "gpt-4o-mini"
        }
    }
}

struct LLMSettings: Codable, Equatable, Sendable {
    var provider: LLMProvider
    var baseURL: String
    var modelName: String
    var apiKey: String
    var customInstructions: String

    static let `default` = LLMSettings(
        provider: .lmStudio,
        baseURL: LLMProvider.lmStudio.defaultBaseURL,
        modelName: LLMProvider.lmStudio.defaultModelName,
        apiKey: "",
        customInstructions: ""
    )
}

enum LLMPreflightState: String, Codable, Sendable {
    case ready
    case misconfigured
    case unavailable
    case authenticationFailed
}

struct LLMPreflightStatus: Equatable, Sendable {
    let state: LLMPreflightState
    let message: String

    var isReady: Bool {
        state == .ready
    }
}

struct InvoiceStructuredDataRecord: Codable, Equatable, Sendable {
    let companyName: String?
    let invoiceNumber: String?
    let invoiceDate: Date?
    let documentType: DocumentType?
    let provider: LLMProvider
    let modelName: String
    let extractedAt: Date
    let schemaVersion: Int

    init(
        companyName: String?,
        invoiceNumber: String?,
        invoiceDate: Date?,
        documentType: DocumentType? = nil,
        provider: LLMProvider,
        modelName: String,
        extractedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.companyName = companyName
        self.invoiceNumber = invoiceNumber
        self.invoiceDate = invoiceDate
        self.documentType = documentType
        self.provider = provider
        self.modelName = modelName
        self.extractedAt = extractedAt
        self.schemaVersion = schemaVersion
    }

    var hasAnyValue: Bool {
        companyName != nil || invoiceNumber != nil || invoiceDate != nil || documentType != nil
    }

    var isHighConfidence: Bool {
        companyName != nil && invoiceDate != nil
    }
}

enum InvoiceOCRState: Equatable, Sendable {
    case waiting
    case success
    case failed
}

enum InvoiceReadState: Equatable, Sendable {
    case waiting
    case success
    case review
    case failed
}

enum FolderRole: String, CaseIterable, Identifiable, Sendable {
    case inbox = "Inbox"
    case processing = "Processing"
    case processed = "Processed"
    case duplicates = "Archive"

    var id: String { rawValue }

    var isRequired: Bool {
        true
    }
}

struct FolderSettings: Equatable, Sendable {
    var inboxURL: URL? = nil
    var processedURL: URL? = nil
    var processingURL: URL? = nil
    var duplicatesURL: URL? = nil

    func url(for role: FolderRole) -> URL? {
        switch role {
        case .inbox:
            return inboxURL
        case .processed:
            return processedURL
        case .processing:
            return processingURL
        case .duplicates:
            return duplicatesURL
        }
    }

    mutating func setURL(_ url: URL?, for role: FolderRole) {
        switch role {
        case .inbox:
            inboxURL = url
        case .processed:
            processedURL = url
        case .processing:
            processingURL = url
        case .duplicates:
            duplicatesURL = url
        }
    }
}

enum HEICOriginalFileHandling: String, CaseIterable, Identifiable, Codable, Sendable {
    case delete
    case archive
    case leaveInUnprocessed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .delete:
            return "Replace"
        case .archive:
            return "Archive"
        case .leaveInUnprocessed:
            return "Leave in Unprocessed"
        }
    }
}

struct HEICConversionSettings: Equatable, Sendable {
    var autoConvertEnabled: Bool
    var originalFileHandling: HEICOriginalFileHandling
    var hasUserConfigured: Bool

    static let `default` = HEICConversionSettings(
        autoConvertEnabled: false,
        originalFileHandling: .delete,
        hasUserConfigured: false
    )
}
