public with sharing class RFPController {

    // ── Upload Action ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Id initiateExtraction(
        Id rfpId,
        Id contentDocumentId,
        Id extractionProfileId,
        Id accountId,
        Id opportunityId
    ) {
        RFP__c rfp = new RFP__c(
            Status__c = 'Processing',
            Processing_Status__c = 'Running AI',
            Source_Document_Id__c = contentDocumentId,
            Extraction_Profile__c = extractionProfileId,
            Account__c = accountId,
            Opportunity__c = opportunityId
        );
        if (rfpId != null) {
            rfp.Id = rfpId;
            update rfp;
        } else {
            insert rfp;
        }

        if (contentDocumentId != null) {
            Boolean alreadyLinked = ![
                SELECT Id
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :contentDocumentId
                  AND LinkedEntityId = :rfp.Id
                LIMIT 1
            ].isEmpty();
            if (!alreadyLinked) {
                insert new ContentDocumentLink(
                    ContentDocumentId = contentDocumentId,
                    LinkedEntityId = rfp.Id,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                );
            }
        }

        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        return rfp.Id;
    }

    @AuraEnabled(cacheable=true)
    public static List<Extraction_Profile__c> getExtractionProfiles() {
        return [
            SELECT Id, Name, Description__c, Is_Default__c
            FROM Extraction_Profile__c
            WHERE Is_Active__c = true
            ORDER BY Is_Default__c DESC, Name ASC

        ];
    }

    // ── Review LWC ───────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ExtractionResultWrapper> getExtractionResults(Id rfpId) {
        List<Extraction_Result__c> results = [
            SELECT Id, Field_Label__c, Extracted_Value__c, Accepted_Value__c,
                   Confidence_Score__c, Citation__c, Review_Status__c, Sort_Order__c,
                   Target_Field_API_Name__c, Category__c, Prompt_Source__c,
                   Extraction_Question__r.Is_Required__c,
                   Extraction_Question__r.Confidence_Threshold__c,
                   Extraction_Question__r.Output_Type__c,
                   Extraction_Question__r.Question_Type__c
            FROM Extraction_Result__c
            WHERE RFP__c = :rfpId
            ORDER BY Category__c ASC NULLS LAST, Sort_Order__c ASC NULLS LAST, CreatedDate ASC

        ];

        List<ExtractionResultWrapper> wrappers = new List<ExtractionResultWrapper>();
        for (Extraction_Result__c r : results) {
            ExtractionResultWrapper w = new ExtractionResultWrapper();
            w.id = r.Id;
            w.fieldLabel = r.Field_Label__c;
            w.extractedValue = r.Extracted_Value__c;
            w.acceptedValue = r.Accepted_Value__c;
            w.confidenceScore = r.Confidence_Score__c;
            w.citation = r.Citation__c;
            w.reviewStatus = r.Review_Status__c;
            w.sortOrder = r.Sort_Order__c;
            w.category = r.Category__c;
            w.isRequired = r.Extraction_Question__r?.Is_Required__c == true;
            w.confidenceThreshold = r.Extraction_Question__r?.Confidence_Threshold__c;
            w.outputType = r.Extraction_Question__r?.Output_Type__c;
            w.questionType = r.Extraction_Question__r?.Question_Type__c;
            w.promptSource = r.Prompt_Source__c;
            wrappers.add(w);
        }
        return wrappers;
    }

    @AuraEnabled
    public static void updateResult(Id resultId, String status, String acceptedValue) {
        update new Extraction_Result__c(
            Id = resultId,
            Review_Status__c = status,
            Accepted_Value__c = acceptedValue
        );
    }

    @AuraEnabled
    public static Integer bulkAccept(Id rfpId, List<Id> resultIds) {
        List<Extraction_Result__c> toAccept = (resultIds != null && !resultIds.isEmpty())
            ? [SELECT Id, Confidence_Score__c, Extraction_Question__r.Confidence_Threshold__c
               FROM Extraction_Result__c
               WHERE RFP__c = :rfpId AND Review_Status__c = 'Pending' AND Id IN :resultIds]
            : [SELECT Id, Confidence_Score__c, Extraction_Question__r.Confidence_Threshold__c
               FROM Extraction_Result__c
               WHERE RFP__c = :rfpId AND Review_Status__c = 'Pending'];

        List<Extraction_Result__c> updating = new List<Extraction_Result__c>();
        for (Extraction_Result__c r : toAccept) {
            Decimal threshold = r.Extraction_Question__r?.Confidence_Threshold__c ?? 80;
            if (r.Confidence_Score__c >= threshold) {
                updating.add(new Extraction_Result__c(
                    Id = r.Id,
                    Review_Status__c = 'Accepted'
                ));
            }
        }

        if (!updating.isEmpty()) {
            update updating;
        }
        return updating.size();
    }

    @AuraEnabled
    public static void finalizeRFP(Id rfpId) {
        RFPFinalizationService.finalize(rfpId);
    }

    @AuraEnabled(cacheable=true)
    public static RFP__c getRFP(Id rfpId) {
        return [
            SELECT Id, Name, Status__c, Processing_Status__c,
                   Processing_Error__c, Overall_Confidence__c,
                   Source_Document_Id__c, Account__c, Opportunity__c
            FROM RFP__c
            WHERE Id = :rfpId

            LIMIT 1
        ];
    }

    // ── Inner class ──────────────────────────────────────────────────────────

    public class ExtractionResultWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public String extractedValue;
        @AuraEnabled public String acceptedValue;
        @AuraEnabled public Decimal confidenceScore;
        @AuraEnabled public String citation;
        @AuraEnabled public String reviewStatus;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public String category;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Decimal confidenceThreshold;
        @AuraEnabled public String outputType;
        @AuraEnabled public String questionType;
        @AuraEnabled public String promptSource;
    }
}
