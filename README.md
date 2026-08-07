# RFP Intake App

A Salesforce application that uses Einstein Generative AI (Prompt Builder) to extract structured data and qualitative insights from one or more RFP source documents uploaded as Salesforce Files. It handles RFP *intake* — capturing and analyzing incoming RFPs — not response authoring.

## Install

### Deploy from source

**Prerequisites**
- [Salesforce CLI v2+](https://developer.salesforce.com/tools/salesforcecli) installed
- An org authenticated with `sf org login web --alias <alias>`
- Einstein Generative AI enabled in the org (Setup → Einstein → Enable)

```bash
git clone https://github.com/tjmks/rfp-agent.git
cd rfp-agent
./scripts/deploy.sh <your-org-alias>
```

This deploys all metadata, assigns the `RFP_Agent` and `EinsteinGPTPromptTemplateUser` permission sets to your user, and seeds a default extraction profile. All four Lightning record pages are automatically activated as the org default on deploy — no manual Lightning App Builder step needed.

Additional implementation notes are in [the Prompt Builder pipeline guide](docs/file-input-prompt-template-pipeline.md), [the record-page deployment guide](docs/salesforce-record-page-deployment.md), and [the Salesforce metadata learnings](docs/salesforce-metadata-learnings.md). The multi-document design record is in [the grounding implementation plan](docs/multi-document-related-list-grounding-plan.md).

---

## How It Works

1. A user opens the `rfpUploadAction` component — placed directly on any Lightning record page via App Builder. The user uploads one or more PDF, PNG, JPEG, or JPG files, selects an **Extraction Profile**, and clicks Submit. This creates (or reruns) an `RFP__c` record, links every selected file, and immediately enqueues an `RFPExtractionQueueable` job. For an existing RFP, every supported file already linked to that RFP is included automatically. Alternatively, the `RFP_Email_Case_Auto_Extraction` flow (shipped as Draft) can trigger extraction from the inbound EmailMessage that created an Email-to-Case Case.
2. The queueable validates the complete supported file corpus linked to the RFP, splits the profile's questions by `Question_Type__c`, and runs **two passes** over that same record-bound corpus:
   - **Extraction** questions → extraction template (default: `RFP_Extract_Questions`, target-compatible GPT5Mini) — strict structured data (dates, contacts, budget).
   - **Reasoning** questions → reasoning template (default: `RFP_Reason_Questions`, target-compatible GPT54) — open-ended analysis (risks, win themes).
   Both templates receive the RFP record and questions JSON; Prompt Builder resolves all linked files through the related-list resource. Each template can be overridden per profile via `Extraction_Template__c` / `Reasoning_Template__c`, but an override must adopt the same three-input contract and related-list provider.
3. Einstein LLM returns a JSON array per pass. `RFPResultParser` parses both into `Extraction_Result__c` records.
4. The queueable rolls up `Overall_Confidence__c` from **extraction results only** (reasoning confidence is fuzzy) and fires the `RFP_Extraction_Complete__e` platform event.
5. The user reviews results in the `rfpExtractionReview` component (lives on the RFP record page), accepting or rejecting each field.
6. When satisfied, the user clicks **Finalize**. `RFPFinalizationService` validates required fields and pushes accepted/edited values to fields on the parent `RFP__c`.

## Data Model

| Object | Purpose |
|---|---|
| `RFP__c` | Root record — links to Account, Opportunity, all source documents through Salesforce Files, and an extraction profile. `Source_Document_Id__c` is retained only as a temporary legacy/primary preview pointer. |
| `Extraction_Profile__c` | Named set of extraction questions (e.g. "Standard RFP Profile"). Optional `Extraction_Template__c` and `Reasoning_Template__c` fields override the org-default Prompt Builder template API names for that profile. |
| `Extraction_Question__c` | Individual question: label, question text, output type, `Question_Type__c` (`Extraction` or `Reasoning`), and `Confidence_Threshold__c` (Extraction only — ignored and not shown in the builder for Reasoning questions) |
| `Extraction_Result__c` | One result per question per RFP — extracted value, confidence score, review status |
| `RFP_Extraction_Complete__e` | Platform event fired when a batch of extraction results is ready |

## Apex Classes

| Class | Purpose |
|---|---|
| `RFPController` | `@AuraEnabled` methods for LWC — load RFP, profiles, results; trigger extraction; bulk accept |
| `RFPFileService` | Validates supported file types, count/aggregate size, access, duplicate-safe links, and session-only unlinking |
| `RFPExtractionAction` | `@InvocableMethod` entry point for Flow and Process Builder — same pipeline as the LWC; accepts `caseId`, `contentDocumentId`, `extractionProfileId`, `accountId`, `opportunityId` |
| `RFPExtractionQueueable` | Async job that calls the Prompt Builder template via `ConnectApi.EinsteinLLM` |
| `RFPResultParser` | Parses and validates the LLM JSON response into `Extraction_Result__c` records |
| `RFPFinalizationService` | Validates required results and writes accepted/edited values to the parent `RFP__c` during Finalize |
| `RFPExtractionException` | Typed exception for extraction errors |

## Lightning Web Components

| Component | Where to add | Purpose |
|---|---|---|
| `rfpUploadAction` | Any Lightning record page via App Builder | Multi-file upload form — attach PDF/PNG/JPEG/JPG files, select an extraction profile, link to Account/Opportunity, and kick off extraction. Existing RFP files remain in the corpus; removing a newly uploaded file removes only its current-session link. |
| `rfpExtractionReview` | RFP__c record page | Main review UI — shows extraction progress, results grouped by category, accept/reject/edit controls, bulk accept, and Finalize |
| `rfpConfidenceBadge` | Sub-component | Colour-coded confidence score badge (green ≥80%, yellow ≥60%, red <60%); thresholds are configured per question via the `Confidence_Threshold__c` field on each Extraction Question |
| `rfpResultField` | Sub-component | Individual result row with accept/reject/edit controls and full keyboard navigation (Enter/Escape/j/k/e) |

## Review UI

The `rfpExtractionReview` component has four filter chips (**All / Pending / Required / Low Confidence**) and three approval actions. Its toolbar reports how many source files are in the record-bound corpus and opens all linked files in Salesforce's file preview; the RFP **Related** tab also exposes the Files related list.

- **Row checkmark (per field):** Marks a single extracted value as Accepted. You can also edit the value (saves as Edited) or reject it. These actions only update the `Review_Status__c` on that `Extraction_Result__c` record — nothing is written to the RFP yet.
- **Bulk Accept ≥ Threshold:** Accepts all Pending results whose `Confidence_Score__c` meets or exceeds the per-question `Confidence_Threshold__c` (default 80). The UI updates immediately; a background sync reconciles with the server.
- **Finalize button:** The commit step for the RFP. Disabled until all required fields have been reviewed; optional fields may remain Pending. When clicked, `RFPFinalizationService` writes every Accepted/Edited value to its mapped field on the `RFP__c` record, then sets `Status__c = 'Approved'` and `Processing_Status__c = 'Complete'`.

The **Low Confidence** filter shows results where `Confidence_Score__c < Confidence_Threshold__c`. Thresholds are set per question via the `Confidence_Threshold__c` field on each Extraction Question (default 80; not applied to Reasoning questions).

In short: checkmarks are your per-field approvals; Finalize is what actually updates the record.

## Prompt Builder Templates

Two `einstein_gpt__flex` templates (`genAiPromptTemplates/`) share the same contract and return the same `[{ id, value, confidence, citation }]` JSON array:

- required `RFPRecord` (`SOBJECT://RFP__c`)
- required `QuestionsJSON` (`primitive://String`)
- optional `GroundingContext` (`primitive://String`)

Neither default template declares `RFPDocument`. Both resolve the complete corpus with the server-validated `{!$RelatedList:RFPRecord.CombinedAttachments.Records}` resource, using the `RFPRecord` Flex input alias as the parent boundary. In this org, the otherwise plausible object-qualified `{!$RelatedList:RFP__c.CombinedAttachments.Records}` form was rejected by Metadata API validation. Salesforce Files must be visible to the running user, and the RFP page layout must expose the Files/related-list configuration used by the provider. The implementation rejects unsupported extensions and a corpus over 10 files or 15 MB before a model call; provider/model-specific limits can be stricter.

| Template | Handles | Intended model |
|---|---|---|
| `RFP_Extract_Questions` | `Extraction` questions — strict structured data | **sfdc_ai__DefaultGPT5Mini** in the validated target org |
| `RFP_Reason_Questions` | `Reasoning` questions — open-ended analysis | **sfdc_ai__DefaultGPT54** in the validated target org |

**Model pinning:** keep each target org's active model choice when promoting a new version. If a model isn't available in another org, open the template in Prompt Builder and set the model in the model picker, or replace `<primaryModel>` with the exact model API name from that org's Einstein model list and redeploy. The `<primaryModel>` value is a Salesforce gateway API name, **not** a raw model ID.

**Per-profile template overrides:** set `Extraction_Template__c` and/or `Reasoning_Template__c` on an `Extraction_Profile__c` record to point that profile at a different Prompt Builder template API name. Leave blank to use the org defaults above. This lets you maintain, for example, a "Government RFP" profile that uses a compliance-focused extraction template while the standard profile uses the defaults — without any Apex changes.

## Permission Set

`RFP_Agent` — grants full CRUD on all four custom objects, field-level access to the permissionable fields in this app, visibility for the four custom tabs and `RFP_App`, and access to the Apex classes. The app and tab metadata are therefore dependencies of this permission set. Assign it together with the org's Prompt Builder execution permission; the deploy script attempts to assign `EinsteinGPTPromptTemplateUser`, while newer Salesforce orgs may expose the equivalent `Execute Prompt Templates` permission through Prompt Template Manager.

```bash
sf org assign permset --name RFP_Agent --target-org <alias>
sf org assign permset --name EinsteinGPTPromptTemplateUser --target-org <alias>
```

## App Home Page & Dashboard

The **RFP Intake App** (`RFP_App`) ships with a home page (`RFP_Agent_Home_Page`) that embeds a classic Salesforce dashboard. The home page is automatically assigned to the app on deploy via `actionOverrides` on the `CustomApplication` — no manual App Builder step needed.

The dashboard (`RFP_Agent_Dashboard`) has three columns:

| Column | Component | Source report |
|---|---|---|
| Left | Donut — RFPs by Status | `RFPs_by_Status` |
| Middle | Donut — RFPs by Extraction Profile | `RFP_By_Profile` |
| Right | Metric — Total RFPs | `RFPs_by_Status` |
| Right | Metric — Avg Confidence Score (30d) | `RFP_Confidence_Avg` |

All four reports are in the `RFP Agent Reports` folder and deploy automatically.

## Record Pages

All four custom objects ship with Lightning record pages. Each page is automatically activated as the org-wide default on deploy via `actionOverrides` in the object metadata — no manual Lightning App Builder step needed.

| Page | Layout | Key components |
|---|---|---|
| **RFP** | Header + right sidebar | Tabs: Details / Review (`rfpExtractionReview`) / Related (Extraction Results, Files). Sidebar: `rfpUploadAction` for re-running or uploading a new version. |
| **Extraction Profile** | Header + two column | Tabs: Details / Questions &amp; Grounding (the `Grounding_Context__c` field plus the Extraction Questions and RFPs-using-this-profile related lists) |
| **Extraction Question** | Header + two column | Tabs: Details / Results (Extraction Results for this question across all RFPs) |
| **Extraction Result** | Header + two column | Tabs: Details (no child objects — leaf node) |

Related lists are defined in the page layout XML using `ChildObject__c.LookupField__c` format (e.g. `Extraction_Result__c.RFP__c`). Column fields are configured in each layout file.

## Deployment

```bash
# Deploy, assign permission sets, and print post-deploy checklist
./scripts/deploy.sh <alias>

# Optional: refresh the default extraction profile (6 Extraction + 3 Reasoning questions)
./scripts/seed_default_profile.sh <alias>
```

The deploy script first deploys the custom objects, Apex classes, LWCs, and record pages so `RFP__c.enableFeeds=true` is live before the Files layout validator runs. It then deploys the full source, the optional Account layout, the permission sets, and the seed data.

### What's automated on deploy

- **Record pages** for all four custom objects are automatically activated as the org-wide default via `actionOverrides` on the object metadata.
- **App home page** (`RFP_Agent_Home_Page`) is automatically assigned to the `RFP_App` Lightning app via `actionOverrides` on the `CustomApplication`.
- **Dashboard & reports** (`RFP_Agent_Dashboard` and four reports in `RFP Agent Reports`) deploy automatically and are immediately available on the home page.
- **Tabs** for all four custom objects (`RFP__c`, `Extraction_Profile__c`, `Extraction_Question__c`, `Extraction_Result__c`) are included in the source and deploy automatically. `Extraction_Question__c` ships with an **All** list view.
- **Tab visibility** is included in the `RFP_Agent` permission set.
- **Flow** (`RFP_Email_Case_Auto_Extraction`) deploys automatically as **Draft** — activate it manually in Setup → Flows if email-triggered auto-extraction is needed.
- **Seed data** — the deploy script creates or refreshes a "Default RFP" profile (`Is_Default__c = true`) with 6 Extraction questions (Project Title, Issuing Organization, Submission Deadline, Estimated Contract Value, Required Capabilities, Primary Contact) and 3 Reasoning questions (Win Themes, Risks & Gaps, Go/No-Go Recommendation). Run `./scripts/seed_default_profile.sh <alias>` to refresh it later, or create questions manually from the **Questions &amp; Grounding** tab on the Extraction Profile record page.

## Email-to-Case Auto Extraction Flow

`RFP_Email_Case_Auto_Extraction` is an EmailMessage-triggered flow that automatically starts extraction for the inbound email that created an Email-to-Case Case. It ships as **Draft** — you must activate it in Setup → Flows if you want this behaviour.

**Required runtime user configuration:** Before activating the flow, open **Setup → Support Settings** and set **Automated Case User** to an active Salesforce user whose user type supports Connect API. The selected user must be Einstein-enabled and have permission to execute Prompt Builder templates (`EinsteinGPTPromptTemplateUser`, or the org's equivalent **Execute Prompt Templates** permission), as well as the `RFP_Agent` permission set and access to the source files. Otherwise, Email-to-Case can create the RFP but the asynchronous extraction can fail with `The Connect API is not enabled for this user type` or a Prompt Builder permissions error. For demo environments, use an Einstein-enabled **System Administrator** user with the Prompt Template User permission. For production, prefer a dedicated, appropriately licensed user with least-privilege access.

**What it does:**
1. Triggers when an inbound `EmailMessage` with a parent record and `HasAttachment = true` is created.
2. Runs asynchronously in a separate transaction after the EmailMessage transaction commits.
3. Calls `RFPExtractionAction` with the EmailMessage ID and parent Case ID.
4. The action verifies `Case.SourceId == EmailMessage.Id`. This excludes manually logged emails, outbound emails, and later replies.
5. The class links every supported PDF/PNG/JPEG/JPG attached to the source EmailMessage, resolves the **default active Extraction Profile**, creates an `RFP__c` record, and enqueues extraction.

**To activate:** Setup → Flows → *RFP Email Case Auto Extraction* → Activate.

**To customise:** Open the flow in Flow Builder and add Decision elements before the action call if you want to filter by Case fields (e.g. only certain queues, record types, or subject keywords). You can also pass an explicit `contentDocumentId` or `extractionProfileId` to the action if you need a specific file or profile rather than auto-discovery.

**Invocable action inputs** (`RFPExtractionAction`):

| Input | Type | Required | Description |
|---|---|---|---|
| `caseId` | Id | — | Backward-compatible Case entry point; includes supported files linked to the Case and its inbound EmailMessages |
| `emailMessageId` | Id | — | Email-to-Case source email; processed only when it equals the parent Case's `SourceId` |
| `contentDocumentId` | Id | — | Singular explicit file override; when supplied it overrides Case auto-discovery |
| `extractionProfileId` | Id | — | Extraction profile to use; defaults to the active default profile |
| `accountId` | Id | — | Account to link to the created RFP |
| `opportunityId` | Id | — | Opportunity to link to the created RFP |

The action returns an `rfpId` output. It throws a descriptive `RFPExtractionException` if no supported Case file can be found or no active default profile exists — the flow will fault with that message, surfacing the issue rather than silently dropping the work.
