---
name: rfp-intake
description: "Create and upload reusable RFP App intake configurations for demo and customer sandbox setup. Use whenever the user links, pastes, or invokes this skill to start guided setup; wants to configure an Extraction_Profile__c/Extraction_Question__c profile for a company evaluating incoming RFPs; needs grounding context; wants questions split into Extraction and Reasoning; provides an evaluator company and any RFP sender context from a sender name to an example RFP; asks to research the evaluator company, sender, or customers; or wants to seed the configuration into a connected Salesforce org after installing the RFP app."
---

# RFP Intake

## Purpose

Use this skill to turn an evaluator company and RFP sender context into a reusable RFP App configuration in Salesforce.

The evaluator company is the company using the app to decide whether and how to respond to incoming RFPs. The RFP sender is the buyer, issuer, procurement team, or prospect that sent the RFP.

The output profile should work across many RFP senders and customers. Do not overfit the questions to one sample RFP, one issuer, or one demo customer.

## Startup Conversation

If the user only links, pastes, or invokes this skill and presses enter, start a guided setup conversation. Do not wait for a more detailed task.

Open by explaining, briefly, that the skill will create a reusable RFP App extraction profile with company grounding, simple document-lookup extraction questions, evaluator-aware reasoning questions, and an optional upload to Salesforce.

Assume the RFP app and its two default Prompt Builder templates are already deployed:

- `RFP_Extract_Questions`
- `RFP_Reason_Questions`

The setup task is to create an extraction profile and questions, not to deploy or modify prompt templates.

Then ask for the minimum needed to begin:

```text
To set this up I need two pieces of context, plus one optional deployment choice:

Required:
- Evaluator company: the company using the app to evaluate RFPs.
- RFP sender context: anything you know about who sends the RFPs, from a sender name or buyer type to an example RFP document. If you want me to choose a likely sender archetype, say "infer".

Optional:
- Salesforce org alias: I can upload the profile, or generate a seed script only.
- Demo focus: industry, product line, geography, or whether this should be the default profile.

What evaluator company should I configure this for, and what do you know about the RFP sender?
```

If the user provides the evaluator company but no sender context, ask one short follow-up and stop. Do not read files, launch research, query Salesforce, or create scripts yet. Proceed only after the user provides sender context or explicitly says `infer`. Before uploading to Salesforce, pause to confirm the target org and whether to write records.

## Inputs

Require:

- Evaluator company name. If missing, ask for it before continuing.
- RFP sender context. This can be as little as a sender company name, buyer type, industry, known customer segment, short description, or an example RFP document. If the user cannot provide it, they must explicitly say `infer`; then infer a sender archetype and mark it as an assumption.

Optional:

- Example RFP document or path.
- Salesforce target org alias. If missing, inspect the connected/default orgs and use the default only when unambiguous.
- Demo/customer context such as target industry, product line, geography, or whether the profile should become the default.

Before writing to Salesforce, confirm the org is a sandbox, scratch org, or explicitly approved demo org. If the org appears to be production or the org type is unclear, stop and ask for confirmation.

## Operating Modes

Use these modes in order.

1. Intake mode: collect evaluator company and sender context. Do not use tools in this mode unless the user attached an RFP file that must be inspected to answer the sender-context question. If sender context is missing, ask for it or ask the user to say `infer`, then stop.
2. Design mode: once evaluator and sender context are present, launch one focused research agent if subagents are available. If subagents are unavailable, do brief inline research. Inspect any example RFP quickly for reusable patterns. Draft the compact grounding context, 7-15 simple Extraction lookup questions, and 2-6 open-ended Reasoning questions.
3. Delivery mode: if no org alias was supplied and the user did not ask for a seed script, return the proposed profile in the response and ask whether to generate/upload a seed script. Do not create files by default.
4. Upload mode: only when the user supplies an org alias or explicitly asks for a seed script/upload, generate an idempotent Apex seed script or equivalent Salesforce data operation. Assume the default prompt templates already exist. Upload only after confirming the target org, then verify and report the records.

## Keep It Lean

This is a straightforward setup workflow. Do not turn it into an open-ended consulting project.

- Ask at most one follow-up round before starting research, unless Salesforce upload safety is unclear.
- Do not make the sender-archetype assumption unless the user says `infer`.
- Keep research bounded to facts that shape grounding context or reusable questions.
- Do not create a long market report. A concise grounding context and practical question set are the deliverables.
- Default to roughly 8-10 Extraction lookup questions and 3 Reasoning questions unless the sender context clearly needs more or less.
- Do not reread all object field metadata during design-only work. The required profile/question fields are listed in this skill. Read repo docs or metadata only when creating a seed script, validating an upload, or resolving a schema error.
- Do not create files unless the user supplied an org alias or explicitly asked for a seed script/file output.

## Research Agent Brief

Ask the research agent to return concise sourced notes for:

- Evaluator company: legal name, business model, offerings, differentiators, industries served, geographies, partner ecosystem, certifications, implementation model, and public constraints or weaknesses.
- RFP sender: if a specific sender is named, gather its industry, procurement context, likely needs, and relationship to the evaluator's market. If only a sender type is provided, summarize the archetype.
- Customers: named customer examples, case studies, testimonials, logo pages, buyer industries, buyer personas, and recurring use cases.
- RFP relevance: what buyers likely procure from this company, what evidence the company can credibly use in a response, and what requirements may create risk.
- Source list: URLs or citation labels for claims. Prefer primary sources: company site, annual reports, trust/security pages, case studies, docs, press releases, public filings.

Use customer evidence to shape the demo. A good profile should feel like it belongs to the evaluator company, not like a generic procurement checklist.

Keep the research result short: enough to support grounding context and question design, not exhaustive background.

## How the Evaluator Shapes the Configuration

Use the evaluator company to decide what matters, but keep the two prompt passes cleanly separated.

- Extraction choices: select short, mostly verbatim RFP facts that matter to intake. Extraction is a lookup pass, not an analysis pass.
- Reasoning choices: compare those extracted facts against the evaluator's offerings, public customer proof, strengths, constraints, and likely response strategy.
- Grounding choices: include only evaluator background that helps assess fit or generate response strategy. Avoid generic company history unless it changes how an RFP should be evaluated.
- Demo choices: use the sender context the user provided. If the user explicitly said `infer`, choose a sender archetype from the evaluator's real customer base so the resulting questions and reasoning feel plausible in a customer sandbox.

If research shows the evaluator serves multiple distinct markets, choose the market that best matches the provided sender context or sample RFP. If the user said `infer`, choose the strongest public customer story or the user's stated demo goal and call out the assumption.

## Example RFP Handling

Supplying an example RFP still makes sense, but its job is calibration, not customization.

Use an example RFP to:

- Learn the common structure, terminology, requirement categories, and evaluation criteria that this evaluator is likely to see.
- Check whether the proposed question set would capture the facts needed for a realistic demo.
- Improve question wording so it handles real procurement language.
- Identify missing reusable categories, such as security requirements, implementation timelines, certification demands, pricing instructions, or submission constraints.

Do not use an example RFP to:

- Create questions that only make sense for that one sender.
- Hard-code the sender's industry, department names, project name, incumbent details, or unique terms into the profile.
- Add niche fields unless they represent a recurring requirement family for the evaluator's market.
- Make the sender's priorities override the evaluator company's broader RFP intake needs.

If the example appears narrow or unusual, call that out and design for the broader evaluator-company use case.

## Sender Handling

If an example RFP is provided, treat the sender as the issuing organization in that document for analysis and validation only. Questions may use broad sender-neutral categories inspired by the example, but they should not name or assume that sender unless the question is a universal field such as `Issuing Organization`.

If no example RFP is provided, use the sender name, buyer type, industry, or short description supplied by the user. Only infer a plausible sender archetype from the evaluator's public customer base when the user explicitly says `infer`. For example, if the evaluator sells clinical diagnostics to hospital labs, the inferred sender archetype might be a hospital network procurement team. Label inferred sender context as an assumption in the final response and in the grounding context.

Do not confuse roles:

- Evaluator/responding company: the app user's company; this belongs in `Grounding_Context__c`.
- Sender/issuer/prospect: the organization that sent an individual RFP; this belongs in extraction results and reasoning at run time, not as a hard-coded profile assumption.

## Grounding Context

Create `Extraction_Profile__c.Grounding_Context__c` as background for the evaluator company. Keep it compact enough for prompt use, usually 400-900 words.

Use this structure:

```text
Evaluator company: <name>
Purpose of this profile: Help <name> evaluate incoming RFPs from <sender or sender archetype>.

Company snapshot:
- ...

Relevant offerings and capabilities:
- ...

Customer and market evidence:
- ...

Likely strengths in RFP responses:
- ...

Known gaps, caveats, or assumptions:
- ...

How to use this context:
- Use it for fit, risk, win theme, and evidence recommendations.
- Do not treat this context as content from the RFP document.
```

Avoid unsupported marketing claims. If a fact is inferred rather than sourced, mark it as an assumption. Do not include confidential customer data unless the user provided it for this purpose.

## Question Design

Create a focused reusable profile with 7-15 Extraction questions and 2-6 Reasoning questions. For a fast demo, fewer high-value questions beat a large generic list. Default to the same level of extraction complexity as the shipped `Default RFP` profile.

Use only supported `Output_Type__c` values: `Text`, `Long Text`, `Number`, `Date`, `Currency`, `Boolean`, `List`.

The app prompt serializes question `id`, `label`, `question_text`, and `output_type`. The current queueable also appends a nonblank `Extraction_Hint__c` to `question_text`, so keep model-critical guidance in `Question_Text__c` and use the hint for concise supporting guidance.

When an RFP has multiple supported Salesforce Files, the prompt grounds against
the complete record-bound corpus. Design reusable questions that work across
the set of source documents, not questions that assume a single example file.

### Extraction Questions

Extraction questions are lookup questions handled by the extraction prompt pass
(the repository currently defaults to `sfdc_ai__DefaultGPT5Mini`, but model
selection is deployment-specific). They must be answerable from the source
documents themselves and should return details that are essentially stated
verbatim in the documents. They should not ask the model to analyze, synthesize,
compare against evaluator capabilities, infer strategy, or produce a broad
narrative summary.

Always include the basic fields every RFP team needs unless the user explicitly excludes them:

- Project Title: "What is the official title or name of the project, program, or solicitation being requested?" Required.
- Issuing Organization: "What is the name of the organization, agency, or company issuing this RFP?" Required.
- Submission Deadline: "What is the deadline for submitting proposals in response to this RFP?" Required.
- Primary Contact: "Who are the points of contact for questions and submissions?" Required unless the user's process does not need contacts.
- Required Capabilities: "List the core capabilities, services, or product categories the responding vendor must provide." Required.
- Estimated Contract Value: "What is the estimated total contract value, budget ceiling, or expected spend for this engagement?" Optional.

Add only a few more extraction fields as simple lookups when they are useful for the evaluator's market:

- Q&A or intent-to-bid deadline
- Contract term
- Submission format or delivery instructions
- Evaluation criteria or scoring weights
- Mandatory certifications or qualifications
- Key legal, security, privacy, data residency, insurance, or SLA requirements
- Required integrations, systems, geographies, support model, or deployment model

Keep extraction questions narrow:

- Ask for one fact family per question.
- Prefer `Text`, `Date`, `Currency`, `Boolean`, or `List`; use `Long Text` sparingly for contacts, submission instructions, or short requirement lists.
- Use simple wording like "What is..." or "List the..." rather than "summarize", "assess", "separate", "identify risks", or "explain".
- Avoid packed questions that combine many subdomains, such as telephony plus workforce plus analytics plus integration requirements.
- Avoid evaluator-specific product analysis in extraction. For example, do not ask whether the RFP fits Service Cloud, which partner capabilities are needed, or how current systems should be replaced.

For the optional example RFP, generalize from the sender's language into reusable lookup fields. For example, turn "Epic Beaker integration" into "Required integrations with existing systems" unless that specific integration is a recurring requirement for the evaluator's target market. If no RFP is provided, use the sender context supplied by the user; if the user said `infer`, choose fields that would make the demo credible for the inferred sender archetype.

Mark only workflow-blocking fields as `Is_Required__c = true`; too many required fields slows demos. Use confidence thresholds around 70-85 for objective fields, lower for broad summaries. Reasoning questions should use threshold 0.

### Reasoning Questions

Reasoning questions are the open-ended analysis path. They should combine the
complete RFP source-document corpus with evaluator context to produce
decision-useful analysis (the repository currently defaults to
`sfdc_ai__DefaultGPT54`, but model selection is deployment-specific). They
should be specific to the evaluator company, but sender-neutral enough to work
for any future RFP. The answer can become sender-specific at extraction time
because the model reads the linked source documents.

Include questions such as:

- Fit summary: where the RFP aligns or conflicts with the evaluator's offerings.
- Win themes: 3-5 themes the response should emphasize, tied to RFP passages and evaluator proof points.
- Customer proof: which public customer stories, industries, or case studies are most relevant.
- Risks and gaps: mandatory requirements, timeline, scope, commercial terms, or capabilities that may be hard to satisfy.
- Competitive posture: likely differentiators and possible incumbent/competitor concerns.
- Clarification questions: questions the response team should ask the sender.
- Go/no-go recommendation: clear `Go`, `No-Go`, or `Conditional Go` with conditions.

Move anything that requires judgment from Extraction to Reasoning. This includes fit, risk, current-state interpretation, replacement strategy, phased rollout interpretation, partner needs, proof-point selection, and recommended response strategy.

Keep each reasoning prompt bounded, usually with "Limit your answer to 250 words or fewer." This keeps the review UI readable.

## Salesforce Upload

Use this section only in Upload mode: when the user supplied a Salesforce org alias or explicitly asked for a seed script/upload. If neither is true, do not create a file; present the profile draft in the response and ask whether they want a seed script or upload.

Assume the org already has the default RFP app prompt templates deployed. Do not deploy, create, or update Prompt Builder templates as part of this skill's normal flow.

Prefer an idempotent Apex seed script similar to `scripts/seed_default_profile.apex`. Generate it in a temporary or user-approved project path, then run:

```bash
sf apex run --file <seed-script.apex> --target-org <alias>
```

The script should:

- Upsert by exact profile `Name`.
- Set `Description__c`, `Grounding_Context__c`, `Is_Active__c = true`, and `Is_Default__c` according to user/demo intent.
- Leave `Extraction_Template__c` and `Reasoning_Template__c` blank to use the deployed defaults (`RFP_Extract_Questions` and `RFP_Reason_Questions`) unless the user explicitly gives custom Prompt Builder template API names.
- Delete and reinsert that profile's existing questions, or otherwise replace them deterministically.
- Insert `Extraction_Question__c` records with `Name`, `Question_Text__c`, `Question_Type__c`, `Output_Type__c`, `Category__c`, `Sort_Order__c`, `Is_Active__c`, `Is_Required__c`, `Confidence_Threshold__c`, and optional `Target_Field_API_Name__c`.

Use valid Apex string escaping. For long grounding context, use joined string chunks rather than one fragile giant literal.

After upload, verify with SOQL:

```bash
sf data query --target-org <alias> --query "SELECT Id, Name, Is_Active__c, Is_Default__c FROM Extraction_Profile__c WHERE Name = '<profile name>'"
sf data query --target-org <alias> --query "SELECT Question_Type__c, COUNT(Id) total FROM Extraction_Question__c WHERE Extraction_Profile__r.Name = '<profile name>' GROUP BY Question_Type__c"
```

If Salesforce CLI is unavailable or the user has not connected an org but did ask for upload/script output, create the seed script and provide the exact command to run after authentication.

## Output

End with:

- Evaluator company and RFP sender context or sender archetype used.
- Profile name and target org alias, if any.
- Counts of Extraction and Reasoning questions.
- Whether the upload succeeded and the profile Id if available, or whether this was a design-only draft.
- Assumptions and research limitations.
- Suggested next validation: generate/upload a seed script if not already done, then upload a sample RFP in the app and review the extracted results.
