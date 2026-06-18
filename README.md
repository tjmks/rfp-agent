# RFP App

A Salesforce application that uses Einstein Generative AI (Prompt Builder) to extract structured data and qualitative insights from RFP documents uploaded as Salesforce Files (ContentDocument).

## Quick Start

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

---

## How It Works

1. A user opens the `rfpUploadAction` component — placed directly on any Lightning record page via App Builder. The user uploads an RFP PDF, selects an **Extraction Profile**, and clicks Submit. This creates an `RFP__c` record linked to the uploaded `ContentDocument` and immediately enqueues an `RFPExtractionQueueable` job. Alternatively, the `RFP_Email_Case_Auto_Extraction` flow (shipped as Draft) can trigger extraction automatically when Email-to-Case creates a Case with a PDF attachment.
2. The queueable splits the profile's questions by `Question_Type__c` and runs **two passes** over the document:
   - **Extraction** questions → `RFP_Extract_Questions` template (Gemini 3.5 Flash) — strict structured data (dates, contacts, budget).
   - **Reasoning** questions → `RFP_Reason_Questions` template (Opus 4.8) — open-ended analysis (risks, win themes).
   Both templates receive the document as a `ContentDocument` input and return the **same JSON contract**.
3. Einstein LLM returns a JSON array per pass. `RFPResultParser` parses both into `Extraction_Result__c` records.
4. The queueable rolls up `Overall_Confidence__c` from **extraction results only** (reasoning confidence is fuzzy) and fires the `RFP_Extraction_Complete__e` platform event.
5. The user reviews results in the `rfpExtractionReview` component (lives on the RFP record page), accepting or rejecting each field.
6. When satisfied, the user clicks **Finalize**. `RFPFinalizationService` validates required fields and pushes accepted/edited values to fields on the parent `RFP__c`.

## Data Model

| Object | Purpose |
|---|---|
| `RFP__c` | Root record — links to Account, Opportunity, source document, and extraction profile |
| `Extraction_Profile__c` | Named set of extraction questions (e.g. "Standard RFP Profile") |
| `Extraction_Question__c` | Individual question: label, question text, output type, `Question_Type__c` (`Extraction` or `Reasoning`), and `Confidence_Threshold__c` (Extraction only — ignored and not shown in the builder for Reasoning questions) |
| `Extraction_Result__c` | One result per question per RFP — extracted value, confidence score, review status |
| `RFP_Extraction_Complete__e` | Platform event fired when a batch of extraction results is ready |

## Apex Classes

| Class | Purpose |
|---|---|
| `RFPController` | `@AuraEnabled` methods for LWC — load RFP, profiles, results; trigger extraction; bulk accept |
| `RFPExtractionAction` | `@InvocableMethod` entry point for Flow and Process Builder — same pipeline as the LWC; accepts `caseId`, `contentDocumentId`, `extractionProfileId`, `accountId`, `opportunityId` |
| `RFPExtractionQueueable` | Async job that calls the Prompt Builder template via `ConnectApi.EinsteinLLM` |
| `RFPResultParser` | Parses and validates the LLM JSON response into `Extraction_Result__c` records |
| `RFPFinalizationService` | Rolls up confidence, updates `RFP__c` status, fires the platform event |
| `RFPExtractionException` | Typed exception for extraction errors |

## Lightning Web Components

| Component | Where to add | Purpose |
|---|---|---|
| `rfpUploadAction` | Any Lightning record page via App Builder | File upload form — attach PDF, select extraction profile, link to Account/Opportunity, and kick off extraction. Drop it directly onto any record page (e.g. the RFP page sidebar, Account page, Opportunity page) for inline access. |
| `rfpExtractionReview` | RFP__c record page | Main review UI — shows extraction progress, results grouped by category, accept/reject/edit controls, bulk accept, and Finalize |
| `rfpQuestionBuilder` | Extraction_Profile__c record page | View and edit profile questions; add/delete/reorder via drag-and-drop; set per-question confidence threshold (Extraction questions only), category, type, and output format; overview and edit modes. Also hosts the **Context & Grounding** editor for the profile-level grounding context applied to all prompts |
| `rfpConfidenceBadge` | Sub-component | Colour-coded confidence score badge (green ≥80%, yellow ≥60%, red <60%); thresholds are configured per question in `rfpQuestionBuilder` |
| `rfpResultField` | Sub-component | Individual result row with accept/reject/edit controls and full keyboard navigation (Enter/Escape/j/k/e) |

## Review UI

The `rfpExtractionReview` component has four filter chips (**All / Pending / Required / Low Confidence**) and three approval actions:

- **Row checkmark (per field):** Marks a single extracted value as Accepted. You can also edit the value (saves as Edited) or reject it. These actions only update the `Review_Status__c` on that `Extraction_Result__c` record — nothing is written to the RFP yet.
- **Bulk Accept ≥ Threshold:** Accepts all Pending results whose `Confidence_Score__c` meets or exceeds the per-question `Confidence_Threshold__c` (default 80). The UI updates immediately; a background sync reconciles with the server.
- **Finalize button:** The commit step for the whole document. Disabled until all required fields have been reviewed (no Pending rows remain). When clicked, `RFPFinalizationService` writes every Accepted/Edited value to its mapped field on the `RFP__c` record, then sets `Status__c = 'Approved'` and `Processing_Status__c = 'Complete'`.

The **Low Confidence** filter shows results where `Confidence_Score__c < Confidence_Threshold__c`. Thresholds are set per question in `rfpQuestionBuilder` (default 80; not applied to Reasoning questions).

In short: checkmarks are your per-field approvals; Finalize is what actually updates the record.

## Prompt Builder Templates

Two `einstein_gpt__flex` templates (`genAiPromptTemplates/`), both receiving a `ContentDocument` file input and a `QuestionsJSON` string, both returning the same `[{ id, value, confidence, citation }]` JSON array:

| Template | Handles | Intended model |
|---|---|---|
| `RFP_Extract_Questions` | `Extraction` questions — strict structured data | **Gemini 3.5 Flash** |
| `RFP_Reason_Questions` | `Reasoning` questions — open-ended analysis | **Opus 4.8** |

**Model pinning:** the templates ship with their intended models set in the XML (`sfdc_ai__DefaultVertexAIGemini35Flash` for `RFP_Extract_Questions`, `sfdc_ai__DefaultBedrockAnthropicClaude48Opus` for `RFP_Reason_Questions`). If a model isn't available in a given org, open the template in Prompt Builder and set the model in the model picker, or replace the `<primaryModel>` value in the template XML with the exact model API name from your org's Einstein model list and redeploy. The `<primaryModel>` value is a Salesforce gateway API name, **not** a raw model ID.

## Permission Set

`RFP_Agent` — grants full CRUD on all four custom objects, field-level access to all permissionable fields, tab visibility for all four custom object tabs, app visibility for `RFP_App`, and access to the Apex classes. Assign this plus the standard **Einstein Generative AI User** permission set to any user who needs to run extractions.

```bash
sf org assign permset --name RFP_Agent --target-org <alias>
sf org assign permset --name EinsteinGPTPromptTemplateUser --target-org <alias>
```

## App Home Page & Dashboard

The **RFP App** (`RFP_App`) ships with a home page (`RFP_Agent_Home_Page`) that embeds a classic Salesforce dashboard. The home page is automatically assigned to the app on deploy via `actionOverrides` on the `CustomApplication` — no manual App Builder step needed.

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
| **Extraction Profile** | Header + two column | Tabs: Details / Configuration (`rfpQuestionBuilder`) / Related (Extraction Questions, RFPs using this profile) |
| **Extraction Question** | Header + two column | Tabs: Details / Results (Extraction Results for this question across all RFPs) |
| **Extraction Result** | Header + two column | Tabs: Details (no child objects — leaf node) |

Related lists are defined in the page layout XML using `ChildObject__c.LookupField__c` format (e.g. `Extraction_Result__c.RFP__c`). Column fields are configured in each layout file.

## Deployment

```bash
# Deploy, assign permission sets, and print post-deploy checklist
./scripts/deploy.sh <alias>

# Optional: seed the default extraction profile (8 Extraction + 3 Reasoning questions)
./scripts/seed_default_profile.sh <alias>
```

The deploy script runs two passes: the `RFP__c` object first (required so `enableFeeds=true` is live before the layout validator runs), then the full source.

### What's automated on deploy

- **Record pages** for all four custom objects are automatically activated as the org-wide default via `actionOverrides` on the object metadata.
- **App home page** (`RFP_Agent_Home_Page`) is automatically assigned to the `RFP_App` Lightning app via `actionOverrides` on the `CustomApplication`.
- **Dashboard & reports** (`RFP_Agent_Dashboard` and four reports in `RFP Agent Reports`) deploy automatically and are immediately available on the home page.
- **Tabs** for all four custom objects (`RFP__c`, `Extraction_Profile__c`, `Extraction_Question__c`, `Extraction_Result__c`) are included in the source and deploy automatically. `Extraction_Question__c` ships with an **All** list view.
- **Tab visibility** is included in the `RFP_Agent` permission set.
- **Flow** (`RFP_Email_Case_Auto_Extraction`) deploys automatically as **Draft** — activate it manually in Setup → Flows if email-triggered auto-extraction is needed.
- **Seed data** — run `./scripts/seed_default_profile.sh <alias>` to create a "Default RFP" profile (`Is_Default__c = true`) with 8 Extraction questions (Project Title, Issuing Organization, Submission Deadline, Estimated Contract Value, Required Capabilities, Primary Contact, Contact Email, Required Submission Format) and 3 Reasoning questions (Win Themes, Risks & Gaps, Go/No-Go Recommendation). Alternatively, create questions manually using the `rfpQuestionBuilder` component.

## Email-to-Case Auto Extraction Flow

`RFP_Email_Case_Auto_Extraction` is a record-triggered flow that automatically starts extraction when Email-to-Case creates a Case. It ships as **Draft** — you must activate it in Setup → Flows if you want this behaviour.

**What it does:**
1. Triggers after a Case is created with `Origin = Email` (async after commit, so all email attachments are already linked).
2. Calls the `RFPExtractionAction` invocable class with the Case ID and Account ID.
3. The class finds the **first PDF** attached to the Case, resolves the **default active Extraction Profile**, creates an `RFP__c` record, and enqueues the extraction job.

**To activate:** Setup → Flows → *RFP Email Case Auto Extraction* → Activate.

**To customise:** Open the flow in Flow Builder and add Decision elements before the action call if you want to filter by Case fields (e.g. only certain queues, record types, or subject keywords). You can also pass an explicit `contentDocumentId` or `extractionProfileId` to the action if you need a specific file or profile rather than auto-discovery.

**Invocable action inputs** (`RFPExtractionAction`):

| Input | Type | Required | Description |
|---|---|---|---|
| `caseId` | Id | — | When `contentDocumentId` is omitted, searches for the first PDF attached to this Case |
| `contentDocumentId` | Id | — | Explicit PDF to extract from; overrides auto-discovery |
| `extractionProfileId` | Id | — | Extraction profile to use; defaults to the active default profile |
| `accountId` | Id | — | Account to link to the created RFP |
| `opportunityId` | Id | — | Opportunity to link to the created RFP |

The action returns an `rfpId` output. It throws a descriptive `RFPExtractionException` if no PDF can be found or no active default profile exists — the flow will fault with that message, surfacing the issue rather than silently dropping the work.
