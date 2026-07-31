public with sharing class RFPController {

    // ── Upload Action ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Id initiateExtraction(
        Id rfpId,
        List<Id> contentDocumentIds,
        Id extractionProfileId,
        Id accountId,
        Id opportunityId
    ) {
        if (rfpId == null && (contentDocumentIds == null || contentDocumentIds.isEmpty())) {
            throw new AuraHandledException(
                'Select at least one PDF, PNG, JPEG, or JPG before starting extraction.'
            );
        }

        RFP__c rfp;
        if (rfpId != null) {
            rfp = [
                SELECT Id, Source_Document_Id__c, Extraction_Profile__c,
                       Account__c, Opportunity__c
                FROM RFP__c
                WHERE Id = :rfpId
                LIMIT 1
            ];
            if (extractionProfileId == null) {
                extractionProfileId = rfp.Extraction_Profile__c;
            }
            if (extractionProfileId == null) {
                throw new AuraHandledException(
                    'Select an active Extraction Profile before starting extraction.'
                );
            }
            rfp.Status__c = 'Processing';
            rfp.Processing_Status__c = 'Running AI';
            rfp.Extraction_Profile__c = extractionProfileId;
            if (accountId != null) rfp.Account__c = accountId;
            if (opportunityId != null) rfp.Opportunity__c = opportunityId;
            update rfp;
        } else {
            if (extractionProfileId == null) {
                throw new AuraHandledException(
                    'Select an active Extraction Profile before starting extraction.'
                );
            }
            rfp = new RFP__c(
                Status__c = 'Processing',
                Processing_Status__c = 'Running AI',
                Extraction_Profile__c = extractionProfileId,
                Account__c = accountId,
                Opportunity__c = opportunityId
            );
            insert rfp;
        }

        // This is bulk-safe and inserts only missing links.  For an existing
        // RFP, pre-attached files remain part of the record-bound corpus even
        // when this upload session adds no new supported file.
        RFPFileService.linkDocuments(rfp.Id, contentDocumentIds);
        RFPFileService.CorpusValidation corpus = RFPFileService.validateRfpCorpus(rfp.Id);

        // Compatibility release: retain a legacy/primary preview pointer, but
        // never use it as Prompt Builder grounding.
        if (String.isBlank(rfp.Source_Document_Id__c) && !corpus.eligibleFiles.isEmpty()) {
            update new RFP__c(
                Id = rfp.Id,
                Source_Document_Id__c = corpus.eligibleFiles[0].contentDocumentId
            );
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

    @AuraEnabled(cacheable=true)
    public static List<RFPFileWrapper> getRFPFiles(Id rfpId) {
        List<RFPFileWrapper> wrappers = new List<RFPFileWrapper>();
        for (RFPFileService.FileInfo file : RFPFileService.getFilesForParent(rfpId)) {
            RFPFileWrapper wrapper = new RFPFileWrapper();
            wrapper.documentId = file.contentDocumentId;
            wrapper.name = file.title;
            wrapper.fileExtension = file.fileExtension;
            wrapper.contentSize = file.contentSize;
            wrapper.supported = file.supported;
            wrapper.exclusionReason = file.exclusionReason;
            wrappers.add(wrapper);
        }
        return wrappers;
    }

    /**
     * A lightning-file-upload on an existing RFP creates the RFP link before
     * the user submits.  Remove only session-created links while preserving
     * the baseline IDs; never delete a ContentDocument.
     */
    @AuraEnabled
    public static void removeSessionFileLinks(
        Id rfpId,
        List<Id> sessionDocumentIds,
        List<Id> preExistingDocumentIds
    ) {
        RFPFileService.removeSessionLinks(rfpId, sessionDocumentIds, preExistingDocumentIds);
    }

    // ── Review LWC ───────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ExtractionResultWrapper> getExtractionResults(Id rfpId) {
        List<Extraction_Result__c> results = [
            SELECT Id, Field_Label__c, Extracted_Value__c, Accepted_Value__c,
                   Confidence_Score__c, Citation__c, Review_Status__c, Sort_Order__c,
                   Target_Field_API_Name__c, Category__c,
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

    // ── Wrappers ────────────────────────────────────────────────────────────

    public class RFPFileWrapper {
        @AuraEnabled public Id documentId;
        @AuraEnabled public String name;
        @AuraEnabled public String fileExtension;
        @AuraEnabled public Integer contentSize;
        @AuraEnabled public Boolean supported;
        @AuraEnabled public String exclusionReason;
    }

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
