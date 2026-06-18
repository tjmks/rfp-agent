public with sharing class RFPExtractionQueueable implements Queueable, Database.AllowsCallouts {

    private static final String EXTRACTION_TEMPLATE = 'RFP_Extract_Questions';
    private static final String REASONING_TEMPLATE = 'RFP_Reason_Questions';
    private static final String REASONING_TYPE = 'Reasoning';

    private static final String EXTRACTION_GROUNDING_HEADER =
        'About the responding company (background context only — do NOT treat as the RFP, and never extract answers from it):';
    private static final String REASONING_GROUNDING_HEADER =
        'About the responding company (use this to assess fit, strengths, weaknesses, and win themes — but ground risk/scope conclusions in the RFP document itself):';

    private Id rfpId;

    public RFPExtractionQueueable(Id rfpId) {
        this.rfpId = rfpId;
    }

    public void execute(QueueableContext ctx) {
        try {
            RFP__c rfp = [
                SELECT Id, Name, Source_Document_Id__c, Extraction_Profile__c,
                       Extraction_Profile__r.Grounding_Context__c,
                       Extraction_Profile__r.Extraction_Template__c,
                       Extraction_Profile__r.Reasoning_Template__c
                FROM RFP__c
                WHERE Id = :rfpId
                LIMIT 1
            ];

            String groundingContext = rfp.Extraction_Profile__r?.Grounding_Context__c;

            List<Extraction_Question__c> allQuestions = [
                SELECT Id, Name, Question_Text__c, Output_Type__c,
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
                String response = invokeTemplate(extractionTemplate, rfp, serializeQuestions(extractionQuestions), groundingContext, EXTRACTION_GROUNDING_HEADER);
                allResults.addAll(RFPResultParser.parse(rfpId, response, extractionQuestions, 'Extraction'));
            }

            if (!reasoningQuestions.isEmpty()) {
                String response = invokeTemplate(reasoningTemplate, rfp, serializeQuestions(reasoningQuestions), groundingContext, REASONING_GROUNDING_HEADER);
                allResults.addAll(RFPResultParser.parse(rfpId, response, reasoningQuestions, 'Reasoning'));
            }

            insert allResults;

            // Roll up overall confidence from extraction results only.
            Decimal totalConfidence = 0;
            Integer extractionCount = 0;
            for (Extraction_Result__c r : allResults) {
                if (extractionQuestionIds.contains(r.Extraction_Question__c) && r.Confidence_Score__c != null) {
                    totalConfidence += r.Confidence_Score__c;
                    extractionCount++;
                }
            }
            Decimal overallConfidence = extractionCount == 0 ? 0 : (totalConfidence / extractionCount).setScale(0);

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

    private static String invokeTemplate(String templateApiName, RFP__c rfp, String questionsJson, String groundingContext, String groundingHeader) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>();
        input.isPreview = false;

        // applicationName must be set or the server NPEs on previewOnly check.
        ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        cfg.applicationName = 'PromptTemplateGenerationsInvocable';
        input.additionalConfig = cfg;

        // Param keys must use the 'Input:' prefix (template referenceName), not the bare apiName.
        // SObject inputs are passed as record references { 'id' => Id }, NOT the full SObject —
        // passing the SObject directly returns "Invalid input value" from Prompt Builder.
        ConnectApi.WrappedValue rfpInput = new ConnectApi.WrappedValue();
        rfpInput.value = new Map<String, Object>{ 'id' => rfp.Id };
        input.inputParams.put('Input:RFPRecord', rfpInput);

        ConnectApi.WrappedValue questionsInput = new ConnectApi.WrappedValue();
        questionsInput.value = questionsJson;
        input.inputParams.put('Input:QuestionsJSON', questionsInput);

        // When grounding context is present, include the section header so the model
        // knows what the block is. When absent, pass empty string — the template renders
        // nothing and the model never sees the section, preventing preamble responses.
        ConnectApi.WrappedValue groundingInput = new ConnectApi.WrappedValue();
        groundingInput.value = String.isBlank(groundingContext)
            ? ''
            : '\n' + groundingHeader + '\n' + groundingContext + '\n';
        input.inputParams.put('Input:GroundingContext', groundingInput);

        ConnectApi.WrappedValue docInput = new ConnectApi.WrappedValue();
        docInput.value = new Map<String, Object>{ 'id' => rfp.Source_Document_Id__c };
        input.inputParams.put('Input:RFPDocument', docInput);

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                templateApiName,
                input
            );

        if (output == null || output.generations == null || output.generations.isEmpty()) {
            throw new RFPExtractionException('Empty response from extraction template.');
        }

        return output.generations[0].text;
    }

    private static String serializeQuestions(List<Extraction_Question__c> questions) {
        List<Map<String, String>> qs = new List<Map<String, String>>();
        for (Extraction_Question__c q : questions) {
            qs.add(new Map<String, String>{
                'id' => q.Id,
                'label' => q.Name,
                'question_text' => q.Question_Text__c,
                'output_type' => q.Output_Type__c
            });
        }
        return JSON.serialize(qs);
    }

    private static void markFailed(Id rfpId, String errorMessage) {
        update new RFP__c(
            Id = rfpId,
            Processing_Status__c = 'Failed',
            Processing_Error__c = errorMessage
        );
        EventBus.publish(new RFP_Extraction_Complete__e(
            RFP_Id__c = rfpId,
            Status__c = 'Failed',
            Error_Message__c = errorMessage.left(255)
        ));
    }
}
