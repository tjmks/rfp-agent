@IsTest
private class RFPControllerTest {

    @TestSetup
    static void setup() {
        Extraction_Profile__c profile = new Extraction_Profile__c(
            Name = 'Controller Test', Is_Active__c = true, Is_Default__c = true
        );
        insert profile;
        List<Extraction_Question__c> questions = new List<Extraction_Question__c>{
            new Extraction_Question__c(
                Name = 'Deadline', Extraction_Profile__c = profile.Id, Question_Text__c = 'When?',
                Question_Type__c = 'Extraction', Output_Type__c = 'Date', Is_Required__c = true,
                Confidence_Threshold__c = 80
            ),
            new Extraction_Question__c(
                Name = 'Budget', Extraction_Profile__c = profile.Id, Question_Text__c = 'How much?',
                Question_Type__c = 'Extraction', Output_Type__c = 'Currency', Confidence_Threshold__c = 80
            )
        };
        insert questions;

        RFP__c rfp = new RFP__c(Extraction_Profile__c = profile.Id, Status__c = 'Needs Review');
        insert rfp;
        insert new List<Extraction_Result__c>{
            new Extraction_Result__c(
                RFP__c = rfp.Id, Extraction_Question__c = questions[0].Id, Field_Label__c = 'Deadline',
                Extracted_Value__c = '2026-12-01', Confidence_Score__c = 95, Review_Status__c = 'Pending',
                Category__c = 'Timeline', Sort_Order__c = 10
            ),
            new Extraction_Result__c(
                RFP__c = rfp.Id, Extraction_Question__c = questions[1].Id, Field_Label__c = 'Budget',
                Extracted_Value__c = '50000', Confidence_Score__c = 40, Review_Status__c = 'Pending',
                Category__c = 'Commercial', Sort_Order__c = 20
            )
        };
    }

    private static RFP__c rfp() {
        return [SELECT Id, Extraction_Profile__c FROM RFP__c LIMIT 1];
    }

    @IsTest
    static void loadsProfilesRfpAndResults() {
        Id rfpId = rfp().Id;

        Assert.areEqual(1, RFPController.getExtractionProfiles().size());
        Assert.areEqual('Needs Review', RFPController.getRFP(rfpId).Status__c);
        Assert.isTrue(RFPController.getRFPFiles(rfpId).isEmpty());

        List<RFPController.ExtractionResultWrapper> results = RFPController.getExtractionResults(rfpId);
        Assert.areEqual(2, results.size());
        Assert.areEqual('Budget', results[0].fieldLabel, 'Commercial sorts before Timeline');
        Assert.isFalse(results[0].isRequired);
        Assert.isTrue(results[1].isRequired);
        Assert.areEqual('Date', results[1].outputType);
    }

    @IsTest
    static void bulkAcceptOnlyTakesResultsAboveThreshold() {
        Id rfpId = rfp().Id;

        Assert.areEqual(1, RFPController.bulkAccept(rfpId, null), 'Only the 95% result clears its 80% threshold');
        Assert.areEqual('Accepted',
            [SELECT Review_Status__c FROM Extraction_Result__c WHERE Field_Label__c = 'Deadline'].Review_Status__c);
        Assert.areEqual(0, RFPController.bulkAccept(rfpId, new List<Id>{ rfpId }), 'Unknown ids accept nothing');
    }

    @IsTest
    static void finalizeRequiresReviewedRequiredAnswers() {
        Id rfpId = rfp().Id;
        try {
            RFPController.finalizeRFP(rfpId);
            Assert.fail('A pending required answer must block approval');
        } catch (RFPExtractionException e) {
            Assert.isTrue(e.getMessage().contains('Deadline'), e.getMessage());
        }

        Extraction_Result__c deadline = [SELECT Id FROM Extraction_Result__c WHERE Field_Label__c = 'Deadline'];
        RFPController.updateResult(deadline.Id, 'Edited', '2026-12-15');
        RFPController.finalizeRFP(rfpId);

        RFP__c approved = [SELECT Status__c, Processing_Status__c FROM RFP__c WHERE Id = :rfpId];
        Assert.areEqual('Approved', approved.Status__c);
        Assert.areEqual('Complete', approved.Processing_Status__c);
    }

    @IsTest
    static void finalizeRejectsReservedAndReadOnlyTargets() {
        Id rfpId = rfp().Id;
        update new List<Extraction_Result__c>{
            new Extraction_Result__c(
                Id = [SELECT Id FROM Extraction_Result__c WHERE Field_Label__c = 'Deadline'].Id,
                Review_Status__c = 'Accepted', Target_Field_API_Name__c = 'Status__c'
            ),
            new Extraction_Result__c(
                Id = [SELECT Id FROM Extraction_Result__c WHERE Field_Label__c = 'Budget'].Id,
                Review_Status__c = 'Accepted', Target_Field_API_Name__c = 'Name'
            )
        };

        try {
            RFPController.finalizeRFP(rfpId);
            Assert.fail('Reserved and read-only targets must fail finalization');
        } catch (RFPExtractionException e) {
            Assert.isTrue(e.getMessage().contains('reserved field'), e.getMessage());
            Assert.isTrue(e.getMessage().contains('not updateable'), e.getMessage());
        }
    }

    @IsTest
    static void initiateExtractionValidatesInputs() {
        RFP__c existing = rfp();
        try {
            RFPController.initiateExtraction(null, new List<Id>(), existing.Extraction_Profile__c, null, null);
            Assert.fail('Starting without files must fail');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }

        update new RFP__c(Id = existing.Id, Extraction_Profile__c = null);
        try {
            RFPController.initiateExtraction(existing.Id, null, null, null, null);
            Assert.fail('Starting without a profile must fail');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }
    }
}
