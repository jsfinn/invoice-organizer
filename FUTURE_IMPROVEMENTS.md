# Future Improvements

This document captures product and implementation improvements discovered during real-world testing.

## Cases

### Distinguish Duplicate Copies From Multipart Invoices

Observed case:
- `MTC020926-1.pdf`
- `MTC020926-2.pdf`

What we observed:
- Both files OCR and structured extraction identify the same invoice number: `5786614`
- Both files also agree on vendor, invoice date, and document type
- The app does not mark them as duplicates because duplicate detection currently depends on extracted-text token similarity and requires near-identical text

Why this matters:
- These files appear to be two parts or pages of the same invoice rather than duplicate copies
- The current model only captures "same extracted text" and misses "same invoice identity"

Potential improvement:
- Add a second grouping mode for files that appear to belong to the same logical invoice based on structured fields such as vendor, invoice number, and invoice date
- Keep this separate from duplicate-copy detection so true duplicate scans can still be blocked without collapsing multipart documents into the wrong workflow state
