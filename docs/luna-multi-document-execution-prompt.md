# Luna Execution Prompt

> **Historical execution prompt.** The multi-document feature described here is
> implemented in the repository. This file is retained as an audit trail for
> the original execution; its original instruction not to commit or push was
> superseded when the user explicitly requested the documentation commit and
> push.

You are Luna operating at maximum effort. Work directly in:

`/Users/tmuenks/coding/projects/rfp_agent`

Implement the multi-document Prompt Builder grounding feature end to end.
Read and follow this plan first:

`/Users/tmuenks/coding/projects/rfp_agent/docs/multi-document-related-list-grounding-plan.md`

The connected Salesforce test org is:

`admin@stf-tm2026.demo`

You are authorized to make the in-scope repository changes, deploy the
in-scope metadata to that test org, activate the new prompt template versions,
and create clearly prefixed `MULTIDOC-TEST-*` records/files needed for
verification. Do not modify or delete pre-existing org records/files. Do not
delete unrelated local files. Preserve all unrelated working-tree changes.

Use the applicable Salesforce/Agentforce, Apex, Flow, LWC, deployment, and
testing skills. Use official Salesforce documentation for unstable platform
details. Do not stop after editing metadata or after a successful deploy:
execute the full validation loop in the target org and iterate until the
acceptance criteria pass or a genuine external blocker is proven.

Important baseline facts:

- The org is API 67.0; the repo currently targets API 63.0.
- The target RFP object currently has `enableFeeds=false` and its retrieved
  layout lacks the Files related list, even though current repo source already
  contains the desired object/layout configuration.
- The target org has unmanaged old RFP metadata and no deployed
  `RFPExtractionAction`.
- Target active template models differ from the repo:
  - extraction: `sfdc_ai__DefaultGPT5Mini`
  - reasoning: `sfdc_ai__DefaultGPT54`
- Preserve the target active models during feature validation unless a model
  is proven incompatible with related-list file inputs. Do not silently turn
  this task into a model migration.
- Existing `RFP-0011` and `RFP-0008` have two linked PDFs. Treat them as
  read-only evidence only.
- The repository contains unrelated untracked work. Do not overwrite it.

Execution requirements:

1. Inspect `git status` and take a fresh read-only target-org metadata/data
   snapshot outside the repo.
2. Prove the exact related-list file merge resource through Prompt Builder or
   a safely retrieved proof template. The final source uses
   `{!$RelatedList:RFPRecord.CombinedAttachments.Records}` because the
   object-qualified form was rejected by Metadata API validation.
3. Implement the common three-input template contract:
   `RFPRecord`, `QuestionsJSON`, and optional `GroundingContext`.
4. Remove the explicit `RFPDocument` input and Apex binding.
5. Implement multi-file linking and validation in the LWC/controller path.
6. Update Email-to-Case/invocable behavior to use all eligible Case files while
   retaining the explicit singular override for compatibility.
7. Keep `Source_Document_Id__c` as a temporary legacy/primary pointer, not as
   grounding input.
8. Add meaningful Apex tests and any proportionate LWC tests supported by the
   repo.
9. Dry-run and deploy in the staged order required for `enableFeeds`, layout,
   Apex/LWC/Flow, and prompt templates.
10. Activate and retrieve the server-generated prompt template versions; never
    invent version identifiers.
11. Create dedicated complementary and conflicting two-PDF fixtures, invoke
    the real pipeline, and verify both files appear in prompt resolution and
    affect results.
12. Exercise single-file, multi-file, conflict, zero-file, unsupported-file,
    over-limit, LWC/controller, and Case/invocable scenarios as far as the
    platform permits.
13. Update repository documentation.
14. Do not commit or push unless separately asked.

Be skeptical of apparent success. A deployment alone is not proof. A passing
LLM call alone is not proof that both files were grounded. Capture concrete
evidence: deployment IDs, test results, fixture/RFP IDs, ContentDocument links,
resolved prompt/file evidence, active template versions/models, and outputs
that require facts from both documents.

When finished, report:

- concise outcome;
- every changed file;
- architectural decisions and compatibility behavior;
- commands/checks run and their results;
- target-org deployment IDs;
- target-org fixture IDs;
- active template versions and models before/after;
- proof that both documents influenced the output;
- any remaining limitations or manual UI-only checks;
- exact rollback procedure.

If blocked, exhaust safe diagnostics and alternatives first. Then report the
precise blocker, evidence, and the smallest user action needed.

## Repository result

The current source implements the common three-input contract, record-bound
multi-file grounding, multi-file LWC/controller linking, all-eligible-Case
invocable behavior, the compatibility `contentDocumentId` override, and
pre-invocation corpus validation. The active source template versions are
recorded in the metadata files; the test class is
`force-app/main/default/classes/RFPMultiDocumentTest.cls` and the proof template
is `force-app/main/default/genAiPromptTemplates/MULTIDOC_TEST_RelatedListProof.genAiPromptTemplate-meta.xml`.
