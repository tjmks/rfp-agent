public with sharing class RFPExtractionAction {

    public class Request {
        @InvocableVariable(
            label='Case ID'
            description='Optional. When Content Document ID is omitted, all supported PDF, PNG, JPEG, and JPG files linked to this Case become the RFP corpus.'
            required=false
        )
        public Id caseId;

        @InvocableVariable(
            label='Content Document ID'
            description='Optional backward-compatible explicit single-file override. When supplied, only this ContentDocument is linked, even if a Case ID is also supplied.'
            required=false
        )
        public Id contentDocumentId;

        @InvocableVariable(
            label='Extraction Profile ID'
            description='Optional. The Extraction Profile (set of questions) to run against the record-bound Salesforce File corpus. If omitted, the default active profile is used.'
            required=false
        )
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
        description='Creates an RFP record, links all eligible Case files (or one explicit ContentDocument override), and queues record-bound AI extraction.'
        category='RFP Agent'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request request : requests) {
            results.add(process(request));
        }
        return results;
    }

    private static Result process(Request request) {
        if (request == null) {
            throw new RFPExtractionException('An RFP extraction request is required.');
        }

        List<Id> documentIds;
        if (request.contentDocumentId != null) {
            // Preserve the existing singular explicit override semantics.
            documentIds = RFPFileService.validateSelectedDocuments(
                new List<Id>{ request.contentDocumentId }
            ).eligibleDocumentIds();
        } else if (request.caseId != null) {
            documentIds = RFPFileService.getEligibleCaseDocumentIds(request.caseId);
        } else {
            throw new RFPExtractionException(
                'Supply a caseId or an explicit contentDocumentId before triggering extraction.'
            );
        }

        Id profileId = request.extractionProfileId;
        if (profileId == null) {
            List<Extraction_Profile__c> defaults = [
                SELECT Id
                FROM Extraction_Profile__c
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
            Source_Document_Id__c = documentIds[0],
            Extraction_Profile__c = profileId,
            Account__c = request.accountId,
            Opportunity__c = request.opportunityId
        );
        insert rfp;

        // One bulk link operation for every eligible Case file.  The helper
        // skips duplicate or already-existing links without touching source
        // ContentDocument records.
        RFPFileService.linkDocuments(rfp.Id, documentIds);

        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        Result result = new Result();
        result.rfpId = rfp.Id;
        return result;
    }
}
