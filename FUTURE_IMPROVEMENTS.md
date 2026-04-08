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

### Improve OCR-Derived Field Trust And Review

Observed cases:
- `Performance 020426.pdf`
- `Performance Invoice 020426.pdf`

What we observed:
- A PDF with embedded text produced cleaner extraction than an OCR-only variant of the same invoice
- OCR confidence can be high even when the extracted invoice number is wrong
- Slight rotation or skew can change OCR reading order and push the LLM toward the wrong numeric field
- Experimental layout-aware OCR reflow improved some local label/value ordering but also degraded overall document reading order on skewed pages

Why this matters:
- Users cannot be expected to know when OCR-derived invoice numbers or dates are unreliable during normal ingestion
- OCR confidence is not a reliable proxy for field correctness
- We need a workflow cue that is useful without pretending we can always enumerate the correct candidate values

Potential improvements:
- Treat provenance as a trust signal: embedded PDF text is highest trust, OCR from PDFs is lower trust, and OCR from image files is lowest trust
- Add an explicit review/sign-off step for critical OCR-derived fields such as invoice number and invoice date during the `In Progress` phase
- Mark OCR-derived critical fields as `Needs Review` until the user confirms or edits them
- Prefer preserving alternate OCR reconstructions for debugging and comparison, but avoid making layout-reflow text the default until it is robust on slightly rotated or skewed scans

### Detect Metadata-Matching Duplicates Missed By Text Similarity

Observed cases:
- `IMG_3005.jpeg`
- `scan0155.pdf`
- `Performance 020426.pdf`
- `Performance Invoice 020426.pdf`

What we observed:
- These files match exactly on the main data-entry fields used by the app workflow, including vendor, invoice number, invoice date, and document type
- The app still does not group them as duplicates because extracted-text similarity remains below the current duplicate threshold
- In the current archive, these exact metadata matches were the active cases that looked like duplicate or same-invoice misses

Why this matters:
- Users care about whether records represent the same invoice, not just whether the extracted text is near-identical
- Text-similarity duplicate detection is useful for copy detection, but it misses cases where the same invoice exists in different representations

Potential improvements:
- Add a second-stage duplicate or same-invoice matcher based on structured metadata agreement
- Use structured-field agreement as corroborating evidence when text similarity is below threshold but vendor, invoice number, invoice date, and document type all align
- Keep copy-detection and same-invoice grouping as separate concepts in the model and UI

### Merge Cross-Format Duplicate Families

Observed cases:
- `IMG_3022.HEIC`
- `IMG_3022 (1).HEIC`
- `IMG_3022.jpeg`
- `IMG_3022 (1).jpeg`

What we observed:
- The app groups the HEIC files together and the JPEG files together
- It does not merge the HEIC and JPEG pairs into one duplicate family because cross-format extracted-text similarity falls below the duplicate threshold
- The files still share the same vendor, date, and receipt classification, and likely represent the same underlying receipt captured/exported in different formats

Why this matters:
- Users may see one logical receipt split into multiple duplicate groups simply because the file was converted or exported to another image format
- Cross-format variants are common when images are copied out of phones or macOS preview/export flows

Potential improvements:
- Recognize cross-format siblings using metadata agreement plus high-but-subthreshold text similarity
- Consider using shared capture heuristics or content-family matching to merge HEIC/JPEG variants into one logical duplicate family
- Where confidence is insufficient for automatic merge, surface the relationship as a reviewable same-document suggestion
