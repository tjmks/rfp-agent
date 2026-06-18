public with sharing class RFPExtractionAction {

    public class Request {
        @InvocableVariable(label='Case ID' description='Optional. Supply this or Content Document ID (or both). When Content Document ID is omitted, the action finds the first PDF attached to this Case. Throws if neither field resolves to a PDF.' required=false)
        public Id caseId;

        @InvocableVariable(label='Content Document ID' description='Optional. Supply this or Case ID (or both). Explicit PDF to extract from — skips the automatic attachment search. Throws if neither field resolves to a PDF.' required=false)
        public Id contentDocumentId;

        @InvocableVariable(label='Extraction Profile ID' description='Optional. The Extraction Profile (set of questions) to run against the document. If omitted, the default active profile is used automatically. Throws if no default active profile exists.' required=false)
        public Id extractionProfileId;

        @InvocableVariable(label='Account ID' description='Optional. Links the created RFP record to this Account.' required=false)
        public Id accountId;

        @InvocableVariable(label='Opportunity ID' description='Optional. Links the created RFP record to this Opportunity.' required=false)
        public Id opportunityId;
    }

    public class Result {
        @InvocableVariable(label='RFP ID' description='ID of the created RFP record.')
        public Id rfpId;
    }

    @InvocableMethod(
        label='Run RFP Extraction'
        description='Creates an RFP record and queues AI extraction on the attached PDF. Mirrors the rfpUploadAction LWC pipeline.'
        category='RFP Agent'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(process(req));
        }
        return results;
    }

    private static Result process(Request req) {
        Result res = new Result();

        Id docId = req.contentDocumentId;
        if (docId == null && req.caseId != null) {
            docId = findFirstPdf(req.caseId);
        }
        if (docId == null) {
            throw new RFPExtractionException(
                req.caseId != null
                    ? 'No PDF attachment found on Case ' + req.caseId + '. Attach a PDF before triggering extraction.'
                    : 'contentDocumentId is required when caseId is not provided.'
            );
        }

        Id profileId = req.extractionProfileId;
        if (profileId == null) {
            List<Extraction_Profile__c> defaults = [
                SELECT Id FROM Extraction_Profile__c
                WHERE Is_Default__c = true AND Is_Active__c = true
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (defaults.isEmpty()) {
                throw new RFPExtractionException(
                    'No default active Extraction Profile found. Create a profile marked Is_Default and Is_Active, or pass an explicit extractionProfileId.'
                );
            }
            profileId = defaults[0].Id;
        }

        RFP__c rfp = new RFP__c(
            Status__c = 'Processing',
            Processing_Status__c = 'Running AI',
            Source_Document_Id__c = docId,
            Extraction_Profile__c = profileId,
            Account__c = req.accountId,
            Opportunity__c = req.opportunityId
        );
        insert rfp;

        Boolean alreadyLinked = ![
            SELECT Id FROM ContentDocumentLink
            WHERE ContentDocumentId = :docId AND LinkedEntityId = :rfp.Id
            LIMIT 1
        ].isEmpty();
        if (!alreadyLinked) {
            insert new ContentDocumentLink(
                ContentDocumentId = docId,
                LinkedEntityId = rfp.Id,
                ShareType = 'V',
                Visibility = 'AllUsers'
            );
        }

        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        res.rfpId = rfp.Id;
        return res;
    }

    private static Id findFirstPdf(Id caseId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
              AND ContentDocument.FileExtension = 'pdf'
            ORDER BY ContentDocument.CreatedDate ASC
            LIMIT 1
        ];
        return links.isEmpty() ? null : links[0].ContentDocumentId;
    }
}
