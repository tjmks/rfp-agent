# Multi-Document Prompt Grounding Implementation Plan

## Objective

Replace the single `ContentDocument` Prompt Builder input with record-bound
related-list grounding so each extraction and reasoning invocation processes
the bounded collection of supported files linked to an `RFP__c`.

The intended prompt resource is:

```text
{!$RelatedList:RFP__c.CombinedAttachments.Records}
```

The `RFP__c` record is the corpus boundary. Apex passes the RFP record to the
template, and every eligible file linked to that RFP is resolved by Prompt
Builder in one invocation. Individual files are not mapped to Flex template
input slots.

## Guardrails

- Target test org: `admin@stf-tm2026.demo` (alias observed as `STF3`).
- Use that org for deployment and end-to-end testing only after taking a
  metadata and data baseline.
- Do not modify or delete existing RFP records or files for test setup.
- Create clearly named test fixtures, for example `MULTIDOC-TEST-*`.
- Preserve unrelated working-tree changes and untracked files.
- Do not invent Prompt Builder version identifiers. Deploy a new version,
  activate it, and retrieve the server-generated metadata.
- Do not silently change the template models as part of this feature.
- Keep `Source_Document_Id__c` for one compatibility release, but remove it
  from the Prompt Builder invocation contract.

## Baseline Observed on 2026-07-29

### Local repository

- Project source API version: `63.0`.
- Current source already has:
  - `RFP__c.enableFeeds=true`
  - `RelatedFileList` on `RFP__c-RFP Layout`
  - `RFPRecord` inputs on both prompt templates
  - a Files related-list component on the RFP record page
- Current prompt templates still declare required
  `SOBJECT://ContentDocument` input `RFPDocument`.
- `RFPExtractionQueueable` passes `Input:RFPDocument` from
  `Source_Document_Id__c`.
- `rfpUploadAction` allows exactly one file.
- `RFPController.initiateExtraction` accepts exactly one ContentDocument ID.
- `RFPExtractionAction` finds only the first Case PDF.
- No Apex test classes are currently present.
- The working tree contains unrelated untracked files. Preserve them.

### Connected org

- Org ID: `00DHp00000L0BNMMA3`.
- Org API version: `67.0`.
- The RFP metadata is unmanaged in the org rather than an installed `RFP App`
  subscriber package.
- The org contains 12 `RFP__c` records.
- `RFPExtractionAction` is not deployed in the org.
- Retrieved `RFP__c` has `enableFeeds=false`.
- The retrieved RFP layout does not contain `RelatedFileList`.
- Existing useful read-only observations:
  - `RFP-0011` has two linked PDFs and a primary source-document ID.
  - `RFP-0008` has two linked PDFs and no primary source-document ID.
- Active prompt templates are still single-file:
  - `RFP_Extract_Questions`, active version suffix `_10`,
    model `sfdc_ai__DefaultGPT5Mini`
  - `RFP_Reason_Questions`, active version suffix `_8`,
    model `sfdc_ai__DefaultGPT54`
- The target org has multiple historical template versions. A source deploy
  must not accidentally discard history or switch to the repository's
  different model selections without an explicit reason.

The read-only org snapshot used to create this plan is under
`/tmp/rfp_stf_baseline`. The executor must take a fresh snapshot because `/tmp`
is not durable.

## Required Design Decisions

### Corpus membership

All supported files currently linked to the `RFP__c` are in scope. This is
deliberate and must be stated in the UI. Upload selection controls which new
files are linked, but it does not create an invisible subset of already linked
RFP files.

Supported formats must follow the current Prompt Builder/file-model contract.
At minimum, handle PDF, PNG, JPEG, and JPG consistently. Validate aggregate
request size and provider-specific file-count/size behavior in the target org.

### Compatibility

Keep `Source_Document_Id__c` temporarily:

- set it to the first selected file when creating an RFP;
- leave it unchanged on reruns unless it is blank;
- do not use it to ground prompts;
- describe it as a legacy/primary preview pointer;
- replace singular review UI behavior with navigation to the Files related
  list where practical.

### Template contract

Both default templates must use the same three inputs:

1. `RFPRecord` — `SOBJECT://RFP__c`, required
2. `QuestionsJSON` — `primitive://String`, required
3. `GroundingContext` — `primitive://String`, optional

Remove `RFPDocument`. This also fixes the current repository mismatch in which
the queueable sends `GroundingContext` to the extraction template even though
that source template does not declare it.

Profile-specific template overrides remain supported. Document that custom
override templates must adopt the new three-input contract and related-list
resource before they are used with the upgraded queueable.

## Implementation Sequence

### Phase 1: Snapshot and prove the platform resource

1. Record `git status`, authenticated org identity, API version, and current
   source tracking state.
2. Retrieve to a fresh directory outside the repo:
   - both `GenAiPromptTemplate` components;
   - `RFP__c`;
   - the RFP layout and FlexiPage;
   - `RFPController`, `RFPExtractionQueueable`, and any existing tests;
   - the Email-to-Case Flow if present.
3. Query the active template models and active version identifiers.
4. In Prompt Builder, or through a safe temporary template version, insert the
   RFP Files/Notes & Attachments resource using the resource picker.
5. Retrieve that proof template and confirm the exact serialized expression.
   Do not assume the UI label, layout identifier, and prompt expression use
   the same API name.
6. Preview against an RFP with two linked PDFs. Confirm that resolution includes
   both binaries before changing application code.
7. If API `63.0` cannot deploy the related-list file resource reliably, test
   with API `67.0`. Raise `sourceApiVersion` only after a scoped dry run shows
   no unrelated metadata churn.

### Phase 2: Prompt templates

Modify:

- `force-app/main/default/genAiPromptTemplates/RFP_Extract_Questions.genAiPromptTemplate-meta.xml`
- `force-app/main/default/genAiPromptTemplates/RFP_Reason_Questions.genAiPromptTemplate-meta.xml`

For each template:

1. Remove the `RFPDocument` input.
2. Add/retain the common three-input contract.
3. Replace the singular document block with the related-list resource.
4. Rewrite instructions from "document" to "source documents".
5. Tell the model to:
   - reason over all supplied files;
   - report conflicting values rather than silently selecting one;
   - prefer explicit/latest authoritative statements when a defensible choice
     is possible;
   - include the source filename in citations when available;
   - retain the existing JSON response contract.
6. Preserve each target org template's active model during the validation
   deployment unless the model cannot process related-list file inputs.
7. Activate the new versions and retrieve them to capture server-generated
   identifiers.
8. Keep only source-appropriate template version metadata in the repository;
   do not paste the entire target org history into source without necessity.

### Phase 3: Apex record grounding

Modify `RFPExtractionQueueable`:

1. Stop selecting `Source_Document_Id__c` for invocation.
2. Remove `Input:RFPDocument`.
3. Continue passing `Input:RFPRecord` as `{ "id": rfp.Id }`.
4. Pass only inputs declared by the common template contract.
5. Before invoking a template, query the RFP's `ContentDocumentLink` records
   and validate:
   - at least one supported file exists;
   - file metadata is readable;
   - the aggregate known size is within the Salesforce limit;
   - error messages identify unsupported/oversized files without exposing file
     content.
6. Perform validation once per queueable execution, not once per prompt pass.
7. Keep the extraction/reasoning two-pass result behavior unchanged.
8. Make methods testable without making a live Einstein call. Prefer a small
   invocation seam/interface or a `@TestVisible` helper over broad production
   branching on `Test.isRunningTest()`.

Create a focused file-link/corpus helper if it makes validation and reuse
between controller, invocable action, and queueable clearer.

### Phase 4: Multi-file LWC and controller

Modify:

- `rfpUploadAction.js`
- `rfpUploadAction.html`
- `rfpUploadAction.css` as needed
- `RFPController.cls`

Required behavior:

1. Enable `lightning-file-upload` multiple selection.
2. Store all returned `{ documentId, name }` values.
3. Render a list of uploaded files and a count.
4. Replace `contentDocumentId` with `List<Id> contentDocumentIds` in
   `initiateExtraction`.
5. Validate IDs, supported extensions, duplicates, and access in Apex.
6. Bulk-insert only missing `ContentDocumentLink` rows.
7. Enqueue extraction only after links exist on the final RFP record.
8. Preserve the first file in `Source_Document_Id__c` for compatibility.
9. Explain in the component that all files already attached to an existing RFP
   are included.
10. When a new upload is attached directly to an existing RFP, removing it
    before submission must remove only the link created in the current upload
    session. Never delete the `ContentDocument`, and never unlink a pre-existing
    RFP file.
11. For Account/Opportunity-hosted uploads, removing a staged file simply
    excludes it from links created on the new RFP; its original host link stays
    intact.

Add an Apex method only if necessary for safe session-created link removal.

### Phase 5: Email-to-Case/invocable path

Modify `RFPExtractionAction` and the Flow descriptions:

1. Replace `findFirstPdf` with retrieval of all supported Case files.
2. Link all eligible Case files to the new RFP in bulk.
3. Retain singular `contentDocumentId` as a backward-compatible explicit
   single-file override.
4. When `contentDocumentId` is absent and `caseId` is supplied, the Case's
   eligible file set becomes the RFP corpus.
5. Do not introduce a collection Flex template input.
6. Deploy the currently missing action before activating or testing the Flow.

### Phase 6: Review UI and documentation

1. Replace singular "Open Document" wording with "View Files".
2. Navigate to `AttachedContentDocuments` on the RFP record where supported.
3. Stop treating a blank `Source_Document_Id__c` as proof that an RFP has no
   documents.
4. Update:
   - `README.md`
   - `docs/file-input-prompt-template-pipeline.md`
   - Flow/action descriptions
   - field metadata description for `Source_Document_Id__c`
5. Document the corpus rule, limits, permissions, page-layout dependency, and
   custom-template override migration.

### Phase 7: Automated tests

Add Apex tests covering:

- zero linked files produces a clear pre-invocation failure;
- one supported file remains compatible;
- two or more supported files are accepted as one record-bound corpus;
- duplicate IDs do not create duplicate links;
- unsupported files do not become the only valid corpus;
- aggregate-size validation;
- existing RFP links are preserved;
- a rerun includes already linked files;
- controller creates all requested links;
- Case invocable links all eligible files;
- explicit `contentDocumentId` retains single-file override semantics;
- primary source field compatibility;
- sharing/FLS-sensitive code fails safely;
- success and failure status/event behavior remains intact.

Run all local/project tests and a target-org Apex test run. If the repo has no
LWC Jest setup, do not fabricate one casually; either add a minimal supported
setup with tests for file-array state or document the manual UI coverage.

## Target-Org Deployment and Test Strategy

### Staged deployment

Because the target org currently has `enableFeeds=false`, deploy in this order:

1. `CustomObject:RFP__c` with `enableFeeds=true`.
2. RFP layout and FlexiPage with Files related-list configuration.
3. Apex, LWC, Flow, permissions, and supporting metadata.
4. New Prompt Builder template versions.
5. Activate the new template versions only after preview resolution succeeds.

Use dry-run/validation deploys before each mutating stage. Do not deploy the
entire dirty repository blindly.

### Fixture setup

Create a new active extraction profile or reuse a known-safe active profile.
Create dedicated test records and two small files with unique facts:

- `MULTIDOC-TEST-A.pdf`: contains a unique value needed by one extraction
  question.
- `MULTIDOC-TEST-B.pdf`: contains a different unique value needed by another
  question.

Also create a conflicting-value pair for one scenario. Keep total size well
below platform/model limits.

### End-to-end scenarios

1. **Single file:** current behavior and JSON parsing remain valid.
2. **Two complementary files:** one invocation/pass resolves facts found only
   in A and only in B.
3. **Conflict:** output flags the conflict and cites both sources.
4. **Existing RFP rerun:** all currently linked eligible files are included.
5. **No files:** queueable fails before Einstein with a clear status/error.
6. **Unsupported file mixed with PDFs:** supported corpus succeeds and excluded
   file behavior is visible.
7. **Over limit:** validation prevents a wasteful call where determinable.
8. **LWC upload:** multiple uploads link to the created/final RFP and render in
   Files.
9. **Case path:** all eligible Case files link to the created RFP.
10. **Permissions/layout:** the runtime user can resolve the related list; a
    deliberately underprivileged user does not silently produce false answers.

For each successful AI scenario, capture:

- RFP ID and linked ContentDocument IDs;
- resolved prompt evidence showing all expected files;
- async job/test result;
- generated extraction/reasoning results;
- filenames present in citations where the model provides them;
- model used and elapsed time.

Do not use `RFP-0011` or `RFP-0008` for mutations. They are useful only as
read-only confirmation that multi-link data already exists.

## Rollback

Before deployment, save:

- retrieved target metadata;
- active template version identifiers and models;
- Apex/LWC/Flow source;
- object, layout, and FlexiPage metadata.

Rollback order:

1. Reactivate the prior prompt template versions.
2. Restore prior Apex/LWC/Flow metadata if application behavior must revert.
3. Leave `enableFeeds=true` and the Files related list in place unless there is
   a demonstrated reason to remove them; they are backward compatible and
   removal would reduce visibility.
4. Preserve test evidence and list any created fixture IDs.

## Acceptance Criteria

- Neither default template declares `RFPDocument`.
- `RFPExtractionQueueable` never binds `Input:RFPDocument`.
- Both default templates ground through the RFP related-list resource.
- Two or more files linked to one RFP are visible in Prompt Builder resolution
  and influence the generated result in one call per pass.
- Files linked only to another record are not included.
- LWC submission links every selected file before enqueueing.
- Email-to-Case links every eligible Case file.
- Single-file behavior remains supported.
- Zero-file and over-limit cases fail clearly before a model call when
  determinable.
- Existing records and unrelated working-tree files are preserved.
- New Apex tests pass locally/deployment-time and in
  `admin@stf-tm2026.demo`.
- Documentation describes the record-bound corpus and migration requirements.
- Final handoff lists changed files, deployment IDs, test results, fixture IDs,
  active template versions/models, unresolved limitations, and rollback steps.

## Authoritative References

- Salesforce Help: Grounding with Related List Merge Fields
  https://help.salesforce.com/s/articleView?id=ai.prompt_builder_ground_related_list.htm
- Salesforce Help: Add a Related List with File Inputs to a Flex Prompt Template
  https://help.salesforce.com/s/articleView?id=ai.prompt_builder_add_related_lists_file_flex.htm
- Salesforce Help: Grounding with File Inputs
  https://help.salesforce.com/s/articleView?id=ai.prompt_builder_ground_file.htm
- Salesforce Help: Prompt Builder Limits
  https://help.salesforce.com/s/articleView?id=ai.prompt_builder_limits.htm
