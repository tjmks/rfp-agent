public with sharing class RFPExtractionAction {

    public class Request {
        @InvocableVariable(
            label='Case ID'
            description='Optional backward-compatible entry point. Includes supported files linked to the Case and its inbound EmailMessage records.'
            required=false
        )
        public Id caseId;

        @InvocableVariable(
            label='Email Message ID'
            description='Optional. For Email-to-Case, identifies the inbound creation email whose Salesforce Files become the RFP corpus.'
            required=false
        )
        public Id emailMessageId;

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

        @InvocableVariable(label='Skipped' description='True when the email is not the source email that created the Case.')
        public Boolean skipped;
    }

    @InvocableMethod(
        label='Run RFP Extraction'
        description='Creates an RFP from an Email-to-Case source email, a Case file corpus, or one explicit ContentDocument, then queues record-bound AI extraction.'
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
        Id effectiveCaseId = request.caseId;
        Id effectiveAccountId = request.accountId;
        Case sourceCase;
        if (request.contentDocumentId != null) {
            // Preserve the existing singular explicit override semantics.
            documentIds = RFPFileService.validateSelectedDocuments(
                new List<Id>{ request.contentDocumentId }
            ).eligibleDocumentIds();
        } else if (request.emailMessageId != null) {
            EmailMessage sourceEmail = getSourceEmail(request.emailMessageId);
            effectiveCaseId = sourceEmail.ParentId;

            sourceCase = [
                SELECT Id, AccountId, SourceId
                FROM Case
                WHERE Id = :effectiveCaseId
                LIMIT 1
            ];
            if (sourceCase.SourceId != sourceEmail.Id) {
                Result skippedResult = new Result();
                skippedResult.skipped = true;
                return skippedResult;
            }

            documentIds = RFPFileService.getEligibleEmailDocumentIds(sourceEmail.Id);
        } else if (effectiveCaseId != null) {
            documentIds = RFPFileService.getEligibleCaseDocumentIds(effectiveCaseId);
        } else {
            throw new RFPExtractionException(
                'Supply an emailMessageId, caseId, or explicit contentDocumentId before triggering extraction.'
            );
        }

        if (effectiveAccountId == null && effectiveCaseId != null) {
            if (sourceCase == null) {
                sourceCase = [
                    SELECT Id, AccountId
                    FROM Case
                    WHERE Id = :effectiveCaseId
                    LIMIT 1
                ];
            }
            effectiveAccountId = sourceCase.AccountId;
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
            Account__c = effectiveAccountId,
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
        result.skipped = false;
        return result;
    }

    private static EmailMessage getSourceEmail(Id emailMessageId) {
        if (emailMessageId.getSObjectType() != EmailMessage.SObjectType) {
            throw new RFPExtractionException(
                'Email Message ID ' + emailMessageId + ' is not an EmailMessage ID.'
            );
        }

        EmailMessage sourceEmail = [
            SELECT Id, ParentId, Incoming
            FROM EmailMessage
            WHERE Id = :emailMessageId
            LIMIT 1
        ];
        if (sourceEmail.Incoming != true) {
            throw new RFPExtractionException('Only inbound EmailMessage records can start Email-to-Case extraction.');
        }
        if (sourceEmail.ParentId == null || sourceEmail.ParentId.getSObjectType() != Case.SObjectType) {
            throw new RFPExtractionException('The inbound EmailMessage must be related to a Case.');
        }
        return sourceEmail;
    }
}
