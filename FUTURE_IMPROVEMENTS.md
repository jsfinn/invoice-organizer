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

Current status:
- Partially improved by the new `structured match + 80% text similarity` rule
- Some metadata-backed duplicate families now auto-group, but the `Performance 020426.pdf` / `Performance Invoice 020426.pdf` case still remains open
- The earlier `IMG_3005.jpeg` / `scan0155.pdf` example no longer reflects the strongest current miss and should be re-validated against the latest archive state before using it as a representative case

Why this matters:
- Users care about whether records represent the same invoice, not just whether the extracted text is near-identical
- Text-similarity duplicate detection is useful for copy detection, but it misses cases where the same invoice exists in different representations

Potential improvements:
- Add a second-stage duplicate or same-invoice matcher based on structured metadata agreement
- Use structured-field agreement as corroborating evidence when text similarity is below threshold but vendor, invoice number, invoice date, and document type all align
- Keep copy-detection and same-invoice grouping as separate concepts in the model and UI

### Merge Cross-Format Duplicate Families

## Scaling

The current archive is roughly 330 invoices for one fiscal year. The target is tens
of thousands. These entries record what breaks on the way there, measured rather
than estimated, so the order of work is not re-argued from intuition.

### Duplicate Detection Is Quadratic And Blocks The Main Actor

What we observed:
- `DuplicateDetector.buildClusters` scores every pair of documents that has extracted text, so the work grows with the square of the library
- Measured with realistic 180-term vectors: 330 invoices takes 0.34s, 2,000 takes 11.9s, 5,000 takes 78.5s
- Extrapolated from the measured per-pair cost: 10,000 invoices is 5.2 minutes, 30,000 is 47 minutes, 50,000 is 131 minutes
- `duplicateGroups` is reached from `LibrarySnapshotBuilder`, called by `AppModel.rebuildLibrarySnapshot()`, which is on the main actor and has fourteen call sites
- Clusters are rebuilt from scratch every time; a single extraction run triggers around 556 rebuilds
- At 30,000 documents the term vectors alone are on the order of a gigabyte resident, because they are rebuilt in memory on each pass

Why this matters:
- This is the first wall, not storage. At 10,000 invoices the UI freezes for five minutes per rebuild, and the 30-second periodic reconcile means it never recovers
- Everything else on this list is survivable in the background; this one costs the application

Potential improvements:
- Block candidates with an inverted index over rare terms so only pairs sharing one are scored, which is the near-linear fix
- Make clustering incremental: one new file should not recluster the library
- Move the rebuild off the main actor (see the separate note on `rebuildLibrarySnapshot`)
- Keep the vectors in the index rather than rebuilding them in memory per pass

Considered and rejected:
- Extracting dedup into a separate service. `DuplicateDetector` already imports only Foundation and is a stateless set of static functions with no I/O, actor, or UI reach, so there is no coupling left to break. A service boundary would not change the algorithm, the call site, or the recomputation, and a network service is a non-starter because the input is raw OCR text containing bank and routing numbers
- A local XPC process stays available if memory isolation later becomes the binding constraint. Being pure and stateless is what keeps that option cheap, and it costs nothing to hold

### Bulk Caches Rewrite The Whole Map On Every Save

What we observed:
- `InvoiceTextStore` and `InvoiceStructuredDataStore` decode the entire map, mutate one key, and re-encode all of it on each `save`
- Current sizes in `UserDefaults`: `workflow.invoiceExtractedText` 2.4MB, `workflow.invoiceStructuredData` 126KB, `workflow.invoiceMetadata` 58KB, `artifact.identityMap` 47KB
- Encoding cost scales with the map: 2.3MB takes 8.3ms, 35MB takes 67ms, 140MB takes 275ms, 350MB takes 699ms
- Because every invoice triggers a whole-map rewrite, a full extraction run is quadratic: 1.4s at 330 invoices, 167s at 5,000, 46 minutes at 20,000, 4.9 hours at 50,000
- At the target size the payload is 140MB to 350MB living in `cfprefsd`, which keeps each domain resident and rewrites the whole plist on flush

Why this matters:
- `UserDefaults` is a preferences store, and this is bulk document text; the medium is wrong before the format is
- Reads are already fronted by `ArtifactComputationCache`, so the remaining cost is entirely on writes
- Writes are coalesced and flushed asynchronously with no transaction spanning the four stores, so a crash can leave the identity map, workflow records, and caches disagreeing

Potential improvements:
- Move to SQLite. Moving the blobs to JSON files in Application Support fixes the medium but leaves the quadratic rewrite in place, so it is not worth spending a migration on
- Design this together with the dedup index: candidate blocking needs an indexed lookup over terms, which is the same query engine, and doing them separately means one schema is thrown away
- Note that a migration is one-way on live customer data. Until now every release could be rolled back because no key or encoding changed; introducing a database ends that, so it needs a backup path

