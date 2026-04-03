# Invoice Organizer

Invoice Organizer is a macOS app for sorting invoice and receipt files through a lightweight operational workflow.

At a high level, it watches three folders:
- `Inbox` for newly arrived files
- `Processing` for invoices currently being reviewed
- `Processed` for completed documents

The app extracts text from PDFs and images, uses that text to detect likely duplicates, and optionally sends the extracted text to an LLM to pull out structured fields such as vendor, invoice number, invoice date, and document type.

## High-Level Processing Flow

1. The app scans the configured folders and loads supported invoice files.
2. Each file gets a stable path-based invoice ID and a content hash.
3. Unprocessed inbox files are queued for text extraction.
4. `DocumentTextExtractor` reads embedded PDF text when possible, otherwise runs OCR.
5. Extracted text is normalized and cached by content hash.
6. Duplicate detection tokenizes the normalized extracted text and compares invoices using Jaccard similarity over those token sets.
7. If LLM extraction is configured, the cached text is sent to the structured extraction client.
8. Structured fields are normalized, cached by content hash, and applied back to the invoice workflow.
9. Users can review, edit, move, ignore, and archive invoices through the queue UI.

## Clear Operational Caches

To reset OCR results, structured extraction results, and saved workflow state without losing app configuration, close the app first and run:

```sh
defaults delete InvoiceOrganizer workflow.invoiceExtractedText || true
defaults delete InvoiceOrganizer workflow.invoiceStructuredData || true
defaults delete InvoiceOrganizer workflow.invoiceMetadata || true
defaults delete InvoiceOrganizer settings.ignoredInvoiceIDs || true

defaults delete com.pkm.invoiceorganizer workflow.invoiceExtractedText || true
defaults delete com.pkm.invoiceorganizer workflow.invoiceStructuredData || true
defaults delete com.pkm.invoiceorganizer workflow.invoiceMetadata || true
defaults delete com.pkm.invoiceorganizer settings.ignoredInvoiceIDs || true
```

This clears:
- OCR / extracted text cache
- structured extraction cache
- saved invoice workflow metadata
- ignored invoice state

This does **not** clear:
- folder paths
- LLM provider / base URL / model / API key
- custom instructions

## Release Process

Create a release by running:

```sh
./release
```

This prints the current `MARKETING_VERSION` and suggests the next patch version. To publish a release, run:

```sh
./release 0.1.4
```

The `release` script:
- updates `MARKETING_VERSION` in `project.yml` and `InvoiceOrganizer.xcodeproj/project.pbxproj`
- increments `CURRENT_PROJECT_VERSION`
- creates a release commit
- creates and pushes tag `v0.1.4`

Pushing the tag triggers the GitHub Actions release workflow, which:
- verifies the tag version matches `project.yml`
- builds the macOS app and packages a DMG
- creates a GitHub Release
- attaches the DMG as a release asset
