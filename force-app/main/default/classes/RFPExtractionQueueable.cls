public with sharing class RFPExtractionQueueable implements Queueable, Database.AllowsCallouts {

    private static final String EXTRACTION_TEMPLATE = 'RFP_Extract_Questions';
    private static final String REASONING_TEMPLATE = 'RFP_Reason_Questions';
    private static final String REASONING_TYPE = 'Reasoning';

    private static final String EXTRACTION_GROUNDING_HEADER =
        'About the responding company (background context only — do NOT treat as the RFP, and never extract answers from it):';
    private static final String REASONING_GROUNDING_HEADER =
        'About the responding company (use this to assess fit, strengths, weaknesses, and win themes — but ground risk/scope conclusions in the source documents themselves):';

    public interface TemplateInvoker {
        String invoke(
            String templateApiName,
            Id rfpId,
            String questionsJson,
            String groundingContext,
            String groundingHeader
        );
    }

    @TestVisible
    private static TemplateInvoker templateInvoker = new ConnectApiTemplateInvoker();

    private Id rfpId;

    public RFPExtractionQueueable(Id rfpId) {
        this.rfpId = rfpId;
    }

    public void execute(QueueableContext ctx) {
        try {
            RFP__c rfp = [
                SELECT Id, Name, Extraction_Profile__c,
                       Extraction_Profile__r.Grounding_Context__c,
                       Extraction_Profile__r.Extraction_Template__c,
                       Extraction_Profile__r.Reasoning_Template__c
                FROM RFP__c
                WHERE Id = :rfpId
                LIMIT 1
            ];

            // Prompt Builder resolves the complete related-list corpus.  This
            // validation is intentionally performed once, before either pass,
            // and never uses Source_Document_Id__c as an input binding.
            RFPFileService.validateRfpCorpus(rfp.Id);

            String groundingContext = rfp.Extraction_Profile__r?.Grounding_Context__c;

            List<Extraction_Question__c> allQuestions = [
                SELECT Id, Name, Question_Label__c, Question_Text__c, Extraction_Hint__c, Output_Type__c,
                       Question_Type__c, Is_Required__c, Sort_Order__c,
                       Target_Field_API_Name__c, Confidence_Threshold__c, Category__c
                FROM Extraction_Question__c
                WHERE Extraction_Profile__c = :rfp.Extraction_Profile__c
                  AND Is_Active__c = true
                ORDER BY Category__c ASC NULLS LAST, Sort_Order__c ASC NULLS LAST
            ];

            if (allQuestions.isEmpty()) {
                markFailed(rfpId, 'No extraction questions found on the selected profile.');
                return;
            }

            List<Extraction_Question__c> extractionQuestions = new List<Extraction_Question__c>();
            List<Extraction_Question__c> reasoningQuestions = new List<Extraction_Question__c>();
            for (Extraction_Question__c q : allQuestions) {
                if (q.Question_Type__c == REASONING_TYPE) {
                    reasoningQuestions.add(q);
                } else {
                    extractionQuestions.add(q);
                }
            }

            List<Extraction_Result__c> allResults = new List<Extraction_Result__c>();
            // Reasoning answers don't return a confidence score, so the overall
            // rollup is restricted to extraction-pass question Ids.
            Set<Id> extractionQuestionIds = new Set<Id>();

            String extractionTemplate = String.isNotBlank(rfp.Extraction_Profile__r?.Extraction_Template__c)
                ? rfp.Extraction_Profile__r.Extraction_Template__c
                : EXTRACTION_TEMPLATE;
            String reasoningTemplate = String.isNotBlank(rfp.Extraction_Profile__r?.Reasoning_Template__c)
                ? rfp.Extraction_Profile__r.Reasoning_Template__c
                : REASONING_TEMPLATE;

            if (!extractionQuestions.isEmpty()) {
                for (Extraction_Question__c q : extractionQuestions) {
                    extractionQuestionIds.add(q.Id);
                }
                String response = invokeTemplate(
                    extractionTemplate,
                    rfp,
                    serializeQuestions(extractionQuestions),
                    groundingContext,
                    EXTRACTION_GROUNDING_HEADER
                );
                allResults.addAll(RFPResultParser.parse(rfpId, response, extractionQuestions));
            }

            if (!reasoningQuestions.isEmpty()) {
                String response = invokeTemplate(
                    reasoningTemplate,
                    rfp,
                    serializeQuestions(reasoningQuestions),
                    groundingContext,
                    REASONING_GROUNDING_HEADER
                );
                allResults.addAll(RFPResultParser.parse(rfpId, response, reasoningQuestions));
            }

            insert allResults;

            Decimal totalConfidence = 0;
            Integer extractionCount = 0;
            for (Extraction_Result__c result : allResults) {
                if (extractionQuestionIds.contains(result.Extraction_Question__c)
                    && result.Confidence_Score__c != null) {
                    totalConfidence += result.Confidence_Score__c;
                    extractionCount++;
                }
            }
            Decimal overallConfidence = extractionCount == 0
                ? 0
                : (totalConfidence / extractionCount).setScale(0);

            update new RFP__c(
                Id = rfpId,
                Status__c = 'Needs Review',
                Processing_Status__c = 'Needs Review',
                Overall_Confidence__c = overallConfidence
            );

            EventBus.publish(new RFP_Extraction_Complete__e(
                RFP_Id__c = rfpId,
                Status__c = 'Success',
                Results_Count__c = allResults.size()
            ));

        } catch (RFPExtractionException e) {
            markFailed(rfpId, e.getMessage());
        } catch (Exception e) {
            markFailed(rfpId, e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private static String invokeTemplate(
        String templateApiName,
        RFP__c rfp,
        String questionsJson,
        String groundingContext,
        String groundingHeader
    ) {
        return templateInvoker.invoke(
            templateApiName,
            rfp.Id,
            questionsJson,
            groundingContext,
            groundingHeader
        );
    }

    private static String serializeQuestions(List<Extraction_Question__c> questions) {
        List<Map<String, String>> qs = new List<Map<String, String>>();
        for (Extraction_Question__c q : questions) {
            String questionText = q.Question_Text__c;
            if (String.isNotBlank(q.Extraction_Hint__c)) {
                questionText += '\nHint: ' + q.Extraction_Hint__c;
            }
            qs.add(new Map<String, String>{
                'id' => q.Id,
                'label' => String.isBlank(q.Question_Label__c) ? q.Name : q.Question_Label__c,
                'question_text' => questionText,
                'output_type' => q.Output_Type__c
            });
        }
        return JSON.serialize(qs);
    }

    private static void markFailed(Id failedRfpId, String errorMessage) {
        update new RFP__c(
            Id = failedRfpId,
            Processing_Status__c = 'Failed',
            Processing_Error__c = errorMessage
        );
        EventBus.publish(new RFP_Extraction_Complete__e(
            RFP_Id__c = failedRfpId,
            Status__c = 'Failed',
            Error_Message__c = errorMessage.left(255)
        ));
    }

    private class ConnectApiTemplateInvoker implements TemplateInvoker {
        public String invoke(
            String templateApiName,
            Id recordId,
            String questionsJson,
            String groundingContext,
            String groundingHeader
        ) {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.inputParams = new Map<String, ConnectApi.WrappedValue>();
            input.isPreview = false;

            // applicationName must be set or runtime generation can fail before
            // the provider resolves the record-bound related list.
            ConnectApi.EinsteinLlmAdditionalConfigInput cfg =
                new ConnectApi.EinsteinLlmAdditionalConfigInput();
            cfg.applicationName = 'PromptTemplateGenerationsInvocable';
            input.additionalConfig = cfg;

            // The templates share exactly these three inputs.  The file corpus
            // is resolved by {!$RelatedList:RFPRecord.CombinedAttachments.Records};
            // no ContentDocument is bound here.
            ConnectApi.WrappedValue rfpInput = new ConnectApi.WrappedValue();
            rfpInput.value = new Map<String, Object>{ 'id' => recordId };
            input.inputParams.put('Input:RFPRecord', rfpInput);

            ConnectApi.WrappedValue questionsInput = new ConnectApi.WrappedValue();
            questionsInput.value = questionsJson;
            input.inputParams.put('Input:QuestionsJSON', questionsInput);

            ConnectApi.WrappedValue groundingInput = new ConnectApi.WrappedValue();
            groundingInput.value = String.isBlank(groundingContext)
                ? ''
                : '\n' + groundingHeader + '\n' + groundingContext + '\n';
            input.inputParams.put('Input:GroundingContext', groundingInput);

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    templateApiName,
                    input
                );

            if (output == null || output.generations == null || output.generations.isEmpty()) {
                throw new RFPExtractionException('Empty response from prompt template ' + templateApiName + '.');
            }
            return output.generations[0].text;
        }
    }
}
