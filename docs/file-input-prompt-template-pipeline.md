# Salesforce File-Input Prompt Template Pipeline

How to build a Salesforce pipeline that takes a **PDF or image file** as input, runs it through a **Prompt Builder template** with a set of instructions, parses the structured response, and deploys the whole thing. This document is a reusable blueprint distilled from the RFP application; its first ten sections show a deliberately generic single-file skeleton, while section 11 documents the repository's implemented record-bound multi-document variant.

The LLM reasoning is fully handled by Prompt Builder (Einstein Generative AI). Apex is only glue: in the generic skeleton it binds one file, while in this repository it validates and links a bounded file corpus, invokes the template, and writes results back to Salesforce.

> **Scope note:** The example names in sections 1–10 (`Job__c`, `Result__c`, and `DocumentReasoningQueueable`) are intentionally generic and are not components in this repository. For the current RFP implementation, use [`README.md`](../README.md) and section 11. Do not copy the example `SourceDocument` input into the shipped RFP templates.

---

## 1. Architecture at a glance

```
User uploads file ──▶ ContentDocument record (Salesforce Files)
                           │
                           ▼
                   Custom record (e.g. Job__c)  ◀── stores status + links
                           │
                           ▼
                Queueable Apex (async)
                           │
                           ▼
       ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate
                           │
                           ▼
              Prompt Builder template (flex)
              - Input: ContentDocument (file)
              - Input: Instructions/Questions JSON (string)
              - Input: parent record reference (optional)
                           │
                           ▼
              LLM returns JSON (per your contract)
                           │
                           ▼
            Apex parses → child Result__c records
                           │
                           ▼
                Platform Event (optional)
                           │
                           ▼
      LWC subscribes via EMP API → renders results
```

Why this shape:

- **Prompt Builder owns the prompt** — admins edit it in the UI without redeploying Apex.
- **`ContentDocument` is the file primitive.** Salesforce ingests the binary, extracts text/images, and hands it to the model. You never call a PDF parser yourself.
- **Apex stays thin** — pick file, pass references, parse JSON, write records.
- **Queueable + Platform Event** keeps the UI responsive for multi-second LLM calls.

---

## 2. Prerequisites

| Requirement | How to check |
|---|---|
| Salesforce CLI v2+ | `sf --version` |
| Org with **Einstein Generative AI** enabled | Setup → Einstein → Einstein Generative AI |
| User has **`EinsteinGPTPromptTemplateUser`** permission set | Setup → Permission Sets |
| A model is provisioned in your org | Setup → Einstein → Models, or query `aiplatform.ModelsAPI` |
| Target model API name (e.g. `sfdc_ai__DefaultVertexAIGemini35Flash`) | Setup → Einstein → Models list |

The deployment script assigns `EinsteinGPTPromptTemplateUser` after metadata deployment. Also grant the org's current Prompt Builder execution permission to runtime users; Salesforce Help currently describes `Execute Prompt Templates` as the relevant permission, exposed through Prompt Template Manager in current orgs. Without the required entitlement, runtime failures can be opaque.

Supported file inputs to `ContentDocument`-typed Prompt Builder inputs include **PDF and common image types** (PNG, JPEG, and provider-dependent JPG aliases). The model the template targets must itself be multimodal for images (Gemini and Claude vision models work; pure text models will reject image content).

---

## 3. Build the Prompt Builder template

The template is the contract between your Apex and the LLM. Build it via Prompt Builder UI or directly as XML metadata.

### 3.1 Minimal `genAiPromptTemplate-meta.xml`

`force-app/main/default/genAiPromptTemplates/Reason_Over_Document.genAiPromptTemplate-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<GenAiPromptTemplate xmlns="http://soap.sforce.com/2006/04/metadata">
    <developerName>Reason_Over_Document</developerName>
    <masterLabel>Reason Over Document</masterLabel>
    <type>einstein_gpt__flex</type>
    <visibility>Global</visibility>
    <templateVersions>
        <inputs>
            <apiName>SourceDocument</apiName>
            <definition>SOBJECT://ContentDocument</definition>
            <masterLabel>Source Document</masterLabel>
            <referenceName>Input:SourceDocument</referenceName>
            <required>true</required>
        </inputs>
        <inputs>
            <apiName>InstructionsJSON</apiName>
            <definition>primitive://String</definition>
            <masterLabel>Instructions JSON</masterLabel>
            <referenceName>Input:InstructionsJSON</referenceName>
            <required>true</required>
        </inputs>
        <inputs>
            <apiName>ParentRecord</apiName>
            <definition>SOBJECT://Job__c</definition>
            <masterLabel>Parent Record</masterLabel>
            <referenceName>Input:ParentRecord</referenceName>
            <required>true</required>
        </inputs>
        <primaryModel>sfdc_ai__DefaultVertexAIGemini35Flash</primaryModel>
        <status>Published</status>
        <content>You are an expert analyst. Read the attached document carefully and produce the requested output.

Document:
{!$Input:SourceDocument}

Parent: {!$Input:ParentRecord.Name}

Instructions:
{!$Input:InstructionsJSON}

Return ONLY a valid JSON array — one entry per instruction, in the same order:
[
  {
    "id": "&lt;instruction id&gt;",
    "value": &lt;value matching the requested output type, or null if not found&gt;,
    "confidence": &lt;decimal 0.0-1.0&gt;,
    "citation": "&lt;brief supporting excerpt (≤100 words), or null&gt;"
  }
]

Do not include any text outside the JSON array.</content>
    </templateVersions>
</GenAiPromptTemplate>
```

Key points the deploy will silently get wrong if you skip them:

| Field | Value | Why |
|---|---|---|
| `<type>` | `einstein_gpt__flex` | Flex templates allow file inputs + Apex invocation. Other types do not. |
| File input `<definition>` | `SOBJECT://ContentDocument` | The single definition that produces a multimodal file input. Not `File`, not `ContentVersion`. |
| `<referenceName>` | `Input:<apiName>` | The exact key Apex must use when binding. |
| `<primaryModel>` | An API name that **exists in your org** | Gateway names like `sfdc_ai__DefaultVertexAIGemini35Flash` or `sfdc_ai__DefaultBedrockAnthropicClaude48Opus` are common — verify in Setup → Einstein → Models. |
| `<content>` placeholders | `{!$Input:<apiName>}` for inputs; `{!$Input:Record.Field}` for SObject fields | Direct interpolation; the file input expands to the document content for the model. |
| JSON braces in `<content>` | Escape `<` and `>` as `&lt;`/`&gt;` | XML safety, not Prompt Builder syntax. |

### 3.2 Authoring tips

- **Build it in Prompt Builder UI first**, click *Save* + *Activate*, then retrieve via `sf project retrieve start --metadata GenAiPromptTemplate:Reason_Over_Document`. The UI fills in `versionIdentifier` / `activeVersionIdentifier` correctly.
- **Test "Preview" in the UI** with a sample ContentDocument record — fastest way to validate the prompt before wiring up Apex.
- **For image inputs**, pick a multimodal model (e.g. Gemini Flash or Claude 4.x). Verify by previewing with a sample image in Prompt Builder.

---

## 4. Data model

Minimum viable schema:

| Object | Purpose |
|---|---|
| `Job__c` (custom) | Operational record — status, error message, link to source document. |
| `Result__c` (custom) | One record per parsed result row. Master-detail or lookup to `Job__c`. |
| `Job_Complete__e` (platform event, optional) | Fired when async processing finishes; LWC subscribes. |

Required `Job__c` fields:

- `Status__c` (picklist: `Processing`, `Needs Review`, `Failed`, `Complete`)
- `Source_Document_Id__c` (text, 18) — ContentDocument Id
- `Processing_Error__c` (long text)

Required `Result__c` fields:

- `Job__c` (master-detail or lookup)
- `Instruction_Id__c` (text) — echo of the LLM's `id` field
- `Extracted_Value__c` (long text)
- `Confidence_Score__c` (number, percent 0–100)
- `Citation__c` (long text)

Object `Job__c` **must have** `<enableFeeds>true</enableFeeds>` if you want the Files related list on the layout — the layout validator rejects `RelatedFileList` otherwise.

---

## 5. Apex: invoke the template

### 5.1 Invocation contract (gotchas)

For the single-file skeleton shown in this section, `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` has four important invocation requirements. All four can produce the same opaque error if missing:

1. **Param keys use the `Input:` prefix** — `Input:SourceDocument`, not `SourceDocument`.
2. **SObject inputs are passed as `{ 'id' => recordId }` maps**, never as full SObjects. This applies to the ContentDocument file input AND to any other SObject input.
3. **`additionalConfig.applicationName` must be set** — use `'PromptTemplateGenerationsInvocable'` for runtime calls.
4. **`isPreview = false`** for runtime calls.

Failure mode for any of the above is identical: ~50 ms response with "Failed to generate Einstein LLM generations response" and no details. A successful call is 1500 ms+.

### 5.2 Queueable Apex

`force-app/main/default/classes/DocumentReasoningQueueable.cls`:

```apex
public with sharing class DocumentReasoningQueueable implements Queueable, Database.AllowsCallouts {

    private static final String TEMPLATE_API_NAME = 'Reason_Over_Document';

    private Id jobId;

    public DocumentReasoningQueueable(Id jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        try {
            Job__c job = [
                SELECT Id, Name, Source_Document_Id__c
                FROM Job__c WHERE Id = :jobId LIMIT 1
            ];

            String instructions = buildInstructionsJson();
            String responseText = invokeTemplate(job, instructions);
            List<Result__c> results = parseResponse(jobId, responseText);
            insert results;

            update new Job__c(Id = jobId, Status__c = 'Needs Review');
        } catch (Exception e) {
            update new Job__c(
                Id = jobId,
                Status__c = 'Failed',
                Processing_Error__c = e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }

    private static String invokeTemplate(Job__c job, String instructionsJson) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>();
        input.isPreview = false;

        ConnectApi.EinsteinLlmAdditionalConfigInput cfg =
            new ConnectApi.EinsteinLlmAdditionalConfigInput();
        cfg.applicationName = 'PromptTemplateGenerationsInvocable';
        input.additionalConfig = cfg;

        // File input — pass ContentDocument as { id: ... }, not as an SObject.
        ConnectApi.WrappedValue docInput = new ConnectApi.WrappedValue();
        docInput.value = new Map<String, Object>{ 'id' => job.Source_Document_Id__c };
        input.inputParams.put('Input:SourceDocument', docInput);

        // String input — pass the value directly.
        ConnectApi.WrappedValue instructionsInput = new ConnectApi.WrappedValue();
        instructionsInput.value = instructionsJson;
        input.inputParams.put('Input:InstructionsJSON', instructionsInput);

        // Parent record input — same { id: ... } pattern.
        ConnectApi.WrappedValue parentInput = new ConnectApi.WrappedValue();
        parentInput.value = new Map<String, Object>{ 'id' => job.Id };
        input.inputParams.put('Input:ParentRecord', parentInput);

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                TEMPLATE_API_NAME, input
            );

        if (output == null || output.generations == null || output.generations.isEmpty()) {
            throw new CalloutException('Empty response from template.');
        }
        return output.generations[0].text;
    }

    private static String buildInstructionsJson() {
        // Replace with your instruction set — could come from a config object,
        // custom metadata, or a related child object.
        List<Map<String, String>> items = new List<Map<String, String>>{
            new Map<String, String>{ 'id' => 'q1', 'text' => 'What is the subject?', 'output_type' => 'Text' },
            new Map<String, String>{ 'id' => 'q2', 'text' => 'When was it issued?',  'output_type' => 'Date' }
        };
        return JSON.serialize(items);
    }

    private static List<Result__c> parseResponse(Id jobId, String raw) {
        String s = raw.trim();
        if (s.startsWith('```')) {
            s = s.replaceAll('(?s)^```[a-z]*\\n?', '').replaceAll('```\\s*$', '').trim();
        }
        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(s);

        List<Result__c> out = new List<Result__c>();
        for (Object item : parsed) {
            Map<String, Object> entry = (Map<String, Object>) item;
            Object rawValue = entry.get('value');
            Decimal confidence = entry.get('confidence') == null
                ? null
                : (((Decimal) entry.get('confidence')) * 100).setScale(0);

            out.add(new Result__c(
                Job__c = jobId,
                Instruction_Id__c = (String) entry.get('id'),
                Extracted_Value__c = rawValue == null ? null : String.valueOf(rawValue),
                Confidence_Score__c = confidence,
                Citation__c = (String) entry.get('citation')
            ));
        }
        return out;
    }
}
```

### 5.3 Entry point — link file to job and enqueue

```apex
public with sharing class DocumentReasoningService {
    public static Id startJob(Id contentDocumentId) {
        Job__c job = new Job__c(
            Status__c = 'Processing',
            Source_Document_Id__c = contentDocumentId
        );
        insert job;

        // Link the uploaded file to the Job so it shows in the Files related list.
        insert new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId = job.Id,
            ShareType = 'V',
            Visibility = 'InternalUsers'
        );

        System.enqueueJob(new DocumentReasoningQueueable(job.Id));
        return job.Id;
    }
}
```

Call `DocumentReasoningService.startJob(...)` from an LWC `@AuraEnabled` method, an `@InvocableMethod` (for Flow), or an Apex trigger.

---

## 6. LWC: upload + watch results (optional)

The minimum frontend is:

1. `lightning-file-upload` bound to a Job__c record (or pre-create the Job__c, then upload).
2. On `uploadfinished`, call the Apex entry point with the new `contentDocumentId`.
3. Subscribe to the `Job_Complete__e` platform event via `lightning/empApi` and refresh.

If a UI isn't required, drop step 2 and call the entry point from a Flow.

---

## 7. Project layout

```
force-app/main/default/
├── classes/
│   ├── DocumentReasoningService.cls
│   ├── DocumentReasoningQueueable.cls
│   └── *.cls-meta.xml        (apiVersion 60.0+)
├── genAiPromptTemplates/
│   └── Reason_Over_Document.genAiPromptTemplate-meta.xml
├── objects/
│   ├── Job__c/...
│   └── Result__c/...
├── permissionsets/
│   └── My_App.permissionset-meta.xml
└── lwc/                       (if you ship a UI)
```

`sfdx-project.json`:

```json
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "63.0"
}
```

Use `sourceApiVersion` **63.0 or higher** — earlier versions don't include the file-input `definition` syntax on `GenAiPromptTemplate`.

---

## 8. Permission set

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>My App</label>
    <objectPermissions>
        <object>Job__c</object>
        <allowCreate>true</allowCreate><allowRead>true</allowRead>
        <allowEdit>true</allowEdit><allowDelete>true</allowDelete>
    </objectPermissions>
    <objectPermissions>
        <object>Result__c</object>
        <allowCreate>true</allowCreate><allowRead>true</allowRead>
        <allowEdit>true</allowEdit><allowDelete>false</allowDelete>
    </objectPermissions>
    <classAccesses>
        <apexClass>DocumentReasoningService</apexClass><enabled>true</enabled>
    </classAccesses>
    <classAccesses>
        <apexClass>DocumentReasoningQueueable</apexClass><enabled>true</enabled>
    </classAccesses>
</PermissionSet>
```

Users **also need** the org's Prompt Builder execution permission — the repository deployment attempts `EinsteinGPTPromptTemplateUser`, while current Salesforce orgs may expose the equivalent `Execute Prompt Templates` permission through Prompt Template Manager.

---

## 9. Deploy

### 9.1 Generic one-shot script example

The following is a minimal script for the generic skeleton, not the repository's `scripts/deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ORG="${1:?Usage: ./scripts/deploy.sh <org-alias>}"

# Single-pass deploy of everything in force-app.
sf project deploy start --source-dir force-app --target-org "$ORG" --wait 30 --concise

# Custom permission set
sf org assign permset --name My_App --target-org "$ORG" || true

# Standard permset required for Einstein template invocation
sf org assign permset --name EinsteinGPTPromptTemplateUser --target-org "$ORG" || true
```

### 9.2 Deploy order rules

If your deploy includes a layout with the Files related list, deploy the object with `<enableFeeds>true</enableFeeds>` **first** (or alone), then the layout. The layout validator checks `enableFeeds` at validation time, not apply time, so a single-batch deploy of a brand-new object with a Files-bearing layout fails on the first run. Once `enableFeeds` is live, subsequent deploys can be single-batch.

For other shapes, a single `sf project deploy start --source-dir force-app` is fine.

### 9.3 Verify deploy

```bash
sf org open --target-org "$ORG" --path /lightning/setup/EinsteinPromptTemplates/home
```

Open your template, click **Preview**, and test with a sample file or parent record matching the template contract. For this repository, preview against an `RFP__c` parent with linked files and inspect the resolved related-list data; a `ContentDocument`-only preview is for the single-file skeleton above.

---

## 10. Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Failed to generate Einstein LLM generations response" (~50 ms) | Missing `Input:` prefix, missing `applicationName`, SObject passed instead of `{id:...}`, or user missing the required Prompt Builder execution permission. |
| Slow failure (~1500 ms+) with same message | LLM-side validation — usually a schema mismatch in the prompt or content policy block. Inspect the template's full prompt text. |
| "Invalid input value for item Input:X" | The input was passed as a full SObject. Use `new Map<String, Object>{ 'id' => rec.Id }`. |
| "Model not provisioned" | The model name in `<primaryModel>` isn't enabled in this org. Pick another from Setup → Einstein → Models. |
| Image input returns "I cannot read images" | The chosen model is text-only. Switch to a vision-capable model (Gemini, Claude 4.x). |
| Empty `generations` array | Template returned no content — usually a malformed prompt or model timeout. Lower the input size or simplify the prompt. |

To get real validation messages instead of the generic error, **test in Prompt Builder Preview first** (set `applicationName = 'PromptBuilderPreview'` if invoking preview from Apex). Preview surfaces the real reason; runtime swallows it.

---

## 11. Multi-document record-bound grounding

For a parent record that owns a bounded file corpus, prefer a related-list file
resource over one `ContentDocument` input. In Prompt Builder, the serialized
resource is:

```text
{!$RelatedList:RFPRecord.CombinedAttachments.Records}
```

The template declares the parent record (`RFPRecord`), the caller's question
JSON (`QuestionsJSON`), and optional background context (`GroundingContext`).
The related-list provider receives the parent record ID and the related-list
name (`CombinedAttachments`); Apex does not loop over files or bind one input
slot per document. The parent qualifier is the template's input alias, so a
template whose parent input is named `RFPRecord` uses
`RFPRecord.CombinedAttachments.Records`; the object-qualified form was rejected
by Metadata API validation in the validated RFP org. This makes the record the
corpus boundary: every supported file linked to that parent is eligible, while
files linked only elsewhere are not.

Salesforce builds related-list grounding from the parent object's page layout
for the current user. If the user cannot see the related list or the associated
object, no related-list data is sent; if the list is empty, the prompt can still
complete successfully without file content. Record-level filters are not
applied, so the application validates the record-bound corpus before invoking
the model.

Validate the corpus before invocation. The RFP implementation accepts PDF,
PNG, JPEG, and JPG at the application layer, excludes unsupported files with a
visible reason, and fails before the model call when no supported file exists
or the known corpus exceeds 10 files or 15 MB. Salesforce's published baseline
is 10 images and 15 MB per request; the repository applies the 10-file count
conservatively to every supported file, and a provider/model may be stricter.
The parent object's Files/related-list layout and the runtime user's file
visibility are prerequisites; a related-list merge can resolve successfully
with no file data when the list is not available to that user, so capture
resolved-prompt evidence during validation.

The queueable reads optional `Extraction_Template__c` and
`Reasoning_Template__c` overrides from the selected profile. An override is
safe only when it implements the same `RFPRecord`, `QuestionsJSON`, and
optional `GroundingContext` contract and exposes the same related-list
provider. The server remains authoritative for count and aggregate-byte
limits; the upload UI reports the selected-file count and server validation
prevents a model call when the stored ContentVersion sizes exceed the limit.

When an upload control attaches a file directly to an existing parent, track
the session's initial document IDs. Removing a staged file should remove only
the newly created `ContentDocumentLink`; never delete the `ContentDocument`,
and never remove a link that was present when the session began. For a new
parent created from an Account or Opportunity upload, removing a staged file
only removes it from the new parent; its original host link remains intact.

For Email-to-Case or other invocable entry points, retain a singular explicit
document ID as a compatibility override, but otherwise discover all eligible
files from the source record and bulk-link them to the new parent before
queueing. Keep any legacy/primary document pointer for previews only; it must
not be passed to the related-list prompt.

## 12. Adapting this to your use case

To turn this skeleton into your specific pipeline:

1. **Rename objects** — `Job__c` → whatever fits (e.g. `Inspection__c`, `Claim__c`, `Document_Review__c`).
2. **Replace `buildInstructionsJson()`** — make it return your domain-specific instruction set. Options:
   - Hard-code in Apex (simplest).
   - Query a config object like `Instruction__c` (admin-editable).
   - Read from Custom Metadata Types (deployable, cached).
3. **Edit the prompt `<content>`** in the template — the LLM's behavior is defined entirely here.
4. **Change the output contract** — if you don't need confidence/citation, simplify the JSON shape and update `parseResponse()` to match.
5. **Pick the right model** — vision-capable for images, fast/cheap for high-volume structured extraction, large/strong for reasoning. Override per-environment by changing `<primaryModel>` and redeploying.
6. **Add validation** — if certain instructions are required, mark them and reject the job in the parser when the LLM returns null.

Everything else (file upload, ContentDocument linkage, Queueable + Platform Event, ConnectApi invocation) stays the same.

## 13. Platform references

- [Grounding with Related List Merge Fields](https://help.salesforce.com/s/articleView?id=ai.prompt_builder_ground_related_list.htm&language=en_US&type=5)
- [Add a Related List with File Inputs to a Flex Prompt Template](https://help.salesforce.com/s/articleView?id=ai.prompt_builder_add_related_lists_file_flex.htm&language=en_US&type=5)
- [Grounding with File Inputs](https://help.salesforce.com/s/articleView?id=ai.prompt_builder_ground_file.htm&language=en_US&type=5)
- [Prompt Builder Limits](https://help.salesforce.com/s/articleView?id=ai.prompt_builder_limits.htm&language=en_US&type=5)
