@IsTest
private class RFPMultiDocumentTest {

    private class RecordedCall {
        String templateApiName;
        Id rfpId;
        String questionsJson;
        String groundingContext;
        String groundingHeader;
        List<String> sourceTitles = new List<String>();
    }

    private class RecordingInvoker implements RFPExtractionQueueable.TemplateInvoker {
        List<RecordedCall> calls = new List<RecordedCall>();

        public String invoke(
            String templateApiName,
            Id rfpId,
            String questionsJson,
            String groundingContext,
            String groundingHeader
        ) {
            RecordedCall call = new RecordedCall();
            call.templateApiName = templateApiName;
            call.rfpId = rfpId;
            call.questionsJson = questionsJson;
            call.groundingContext = groundingContext;
            call.groundingHeader = groundingHeader;
            for (RFPFileService.FileInfo file : RFPFileService.getFilesForParent(rfpId)) {
                call.sourceTitles.add(file.title);
            }
            calls.add(call);

            List<Object> questions = (List<Object>) JSON.deserializeUntyped(questionsJson);
            List<Object> response = new List<Object>();
            for (Object questionValue : questions) {
                Map<String, Object> question = (Map<String, Object>) questionValue;
                response.add(new Map<String, Object>{
                    'id' => question.get('id'),
                    'value' => 'MULTIDOC-TEST-EVIDENCE-A-and-B',
                    'confidence' => 0.95,
                    'citation' => 'MULTIDOC-TEST-A.pdf and MULTIDOC-TEST-B.pdf'
                });
            }
            return JSON.serialize(response);
        }
    }

    @IsTest
    static void testValidationLinksAndSessionRemoval() {
        Id supportedA = createFile('MULTIDOC-TEST-A', 'pdf');
        Id supportedB = createFile('MULTIDOC-TEST-B', 'pdf');
        Id unsupported = createFile('MULTIDOC-TEST-UNSUPPORTED', 'txt');
        RFP__c rfp = createRfp(createProfile());

        RFPFileService.LinkResult linkResult = RFPFileService.linkDocuments(
            rfp.Id,
            new List<Id>{supportedA, supportedB, supportedA, unsupported}
        );
        System.assertEquals(2, linkResult.eligibleDocumentIds.size());
        System.assertEquals(2, linkResult.createdLinkIds.size());
        System.assertEquals(1, linkResult.excludedFileNames.size());

        RFPFileService.LinkResult secondLink = RFPFileService.linkDocuments(
            rfp.Id,
            new List<Id>{supportedA, supportedB}
        );
        System.assertEquals(0, secondLink.createdLinkIds.size(), 'Duplicate links must not be created.');
        System.assertEquals(2, RFPFileService.getFilesForParent(rfp.Id).size());

        RFPFileService.removeSessionLinks(
            rfp.Id,
            new List<Id>{supportedA, supportedB},
            new List<Id>{supportedA}
        );
        List<RFPFileService.FileInfo> remaining = RFPFileService.getFilesForParent(rfp.Id);
        System.assertEquals(1, remaining.size());
        System.assertEquals(supportedA, remaining[0].contentDocumentId);
        Set<Id> createdDocuments = new Set<Id>{supportedA, supportedB};
        System.assertEquals(2, [SELECT COUNT() FROM ContentDocument WHERE Id IN :createdDocuments]);

        try {
            RFPFileService.validateSelectedDocuments(new List<Id>{unsupported});
            System.assert(false, 'An unsupported-only corpus must fail closed.');
        } catch (RFPExtractionException e) {
            System.assert(e.getMessage().contains('No supported Salesforce Files'));
        }

        try {
            RFPFileService.getFilesByDocumentIds(new List<Id>{rfp.Id});
            System.assert(false, 'An RFP ID must not be accepted as a ContentDocument ID.');
        } catch (RFPExtractionException e) {
            System.assert(e.getMessage().contains('not a ContentDocument ID'));
        }
    }

    @IsTest
    static void testAggregateAndCountLimits() {
        List<RFPFileService.FileInfo> tooLarge = new List<RFPFileService.FileInfo>{
            new RFPFileService.FileInfo(null, 'MULTIDOC-TEST-large.pdf', 'pdf', RFPFileService.MAX_TOTAL_BYTES + 1)
        };
        try {
            RFPFileService.validateFilesForTest(tooLarge, 'limit test');
            System.assert(false, 'Aggregate size over the provider limit must fail.');
        } catch (RFPExtractionException e) {
            System.assert(e.getMessage().contains('aggregate limit'));
        }

        List<RFPFileService.FileInfo> tooMany = new List<RFPFileService.FileInfo>();
        for (Integer i = 0; i <= RFPFileService.MAX_FILE_COUNT; i++) {
            tooMany.add(new RFPFileService.FileInfo(null, 'MULTIDOC-TEST-' + i + '.pdf', 'pdf', 1));
        }
        try {
            RFPFileService.validateFilesForTest(tooMany, 'count test');
            System.assert(false, 'File count over the provider limit must fail.');
        } catch (RFPExtractionException e) {
            System.assert(e.getMessage().contains('Prompt Builder limit'));
        }
    }

    @IsTest
    static void testQueueableFailsBeforeInvocationWithNoFiles() {
        Extraction_Profile__c profile = createProfile();
        RFP__c rfp = createRfp(profile);
        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;

        Test.startTest();
        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        Test.stopTest();

        RFP__c failed = [
            SELECT Processing_Status__c, Processing_Error__c
            FROM RFP__c
            WHERE Id = :rfp.Id
        ];
        System.assertEquals('Failed', failed.Processing_Status__c);
        System.assert(failed.Processing_Error__c.contains('No supported Salesforce Files'));
        System.assertEquals(0, invoker.calls.size(), 'No model invocation is allowed for an empty corpus.');
    }

    @IsTest
    static void testQueueableUsesAllLinkedFilesAndPreservesRerunPrimary() {
        Extraction_Profile__c profile = createProfile();
        Extraction_Question__c question = createQuestion(profile, 'MULTIDOC-TEST-combined-fact');
        Id supportedA = createFile('MULTIDOC-TEST-A', 'pdf');
        Id supportedB = createFile('MULTIDOC-TEST-B', 'pdf');
        RFP__c rfp = createRfp(profile);
        RFPFileService.linkDocuments(rfp.Id, new List<Id>{supportedA, supportedB});
        update new RFP__c(Id = rfp.Id, Source_Document_Id__c = String.valueOf(supportedA));

        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;
        Test.startTest();
        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        Test.stopTest();

        RFP__c completed = [
            SELECT Processing_Status__c, Status__c, Source_Document_Id__c
            FROM RFP__c
            WHERE Id = :rfp.Id
        ];
        System.assertEquals('Needs Review', completed.Processing_Status__c);
        System.assertEquals('Needs Review', completed.Status__c);
        System.assertEquals(String.valueOf(supportedA), completed.Source_Document_Id__c);
        System.assertEquals(1, invoker.calls.size());
        System.assert(invoker.calls[0].sourceTitles.contains('MULTIDOC-TEST-A'));
        System.assert(invoker.calls[0].sourceTitles.contains('MULTIDOC-TEST-B'));
        System.assertEquals(1, [SELECT COUNT() FROM Extraction_Result__c WHERE RFP__c = :rfp.Id]);
        System.assertEquals(question.Id, [SELECT Extraction_Question__c FROM Extraction_Result__c WHERE RFP__c = :rfp.Id LIMIT 1].Extraction_Question__c);
    }

    @IsTest
    static void testExistingRfpRerunKeepsAllLinkedFilesAndPrimary() {
        Extraction_Profile__c profile = createProfile();
        createQuestion(profile, 'MULTIDOC-TEST-rerun-fact');
        Id supportedA = createFile('MULTIDOC-TEST-A', 'pdf');
        Id supportedB = createFile('MULTIDOC-TEST-B', 'pdf');
        RFP__c rfp = createRfp(profile);
        RFPFileService.linkDocuments(rfp.Id, new List<Id>{supportedA, supportedB});
        update new RFP__c(Id = rfp.Id, Source_Document_Id__c = String.valueOf(supportedA));
        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;

        Test.startTest();
        RFPController.initiateExtraction(rfp.Id, new List<Id>(), profile.Id, null, null);
        Test.stopTest();
        System.assertEquals(2, RFPFileService.getFilesForParent(rfp.Id).size());
        System.assertEquals(String.valueOf(supportedA), [SELECT Source_Document_Id__c FROM RFP__c WHERE Id = :rfp.Id].Source_Document_Id__c);
        System.assertEquals(1, invoker.calls.size());
        System.assert(invoker.calls[0].sourceTitles.contains('MULTIDOC-TEST-A'));
        System.assert(invoker.calls[0].sourceTitles.contains('MULTIDOC-TEST-B'));
    }

    @IsTest
    static void testProfileTemplateOverrideRemainsSupported() {
        Extraction_Profile__c profile = createProfile();
        profile.Extraction_Template__c = 'MULTIDOC_TEST_RelatedListProof';
        update profile;
        createQuestion(profile, 'MULTIDOC-TEST-override-fact');
        Id supported = createFile('MULTIDOC-TEST-OVERRIDE', 'pdf');
        RFP__c rfp = createRfp(profile);
        RFPFileService.linkDocuments(rfp.Id, new List<Id>{supported});

        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;
        Test.startTest();
        System.enqueueJob(new RFPExtractionQueueable(rfp.Id));
        Test.stopTest();

        System.assertEquals(1, invoker.calls.size());
        System.assertEquals('MULTIDOC_TEST_RelatedListProof', invoker.calls[0].templateApiName);
    }

    @IsTest
    static void testControllerLinksAllRequestedFilesAndSetsLegacyPointer() {
        Extraction_Profile__c profile = createProfile();
        createQuestion(profile, 'MULTIDOC-TEST-controller-fact');
        Id supportedA = createFile('MULTIDOC-TEST-A', 'pdf');
        Id supportedB = createFile('MULTIDOC-TEST-B', 'pdf');
        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;

        Test.startTest();
        Id rfpId = RFPController.initiateExtraction(
            null,
            new List<Id>{supportedA, supportedB, supportedA},
            profile.Id,
            null,
            null
        );
        Test.stopTest();

        System.assertEquals(2, RFPFileService.getFilesForParent(rfpId).size());
        RFP__c rfp = [SELECT Source_Document_Id__c FROM RFP__c WHERE Id = :rfpId];
        System.assertEquals(String.valueOf(supportedA), rfp.Source_Document_Id__c);
        System.assertEquals(1, invoker.calls.size());
    }

    @IsTest(SeeAllData=true)
    static void testCaseInvocableLinksAllFilesAndHonorsExplicitOverride() {
        Extraction_Profile__c profile = createProfile();
        createQuestion(profile, 'MULTIDOC-TEST-case-fact');
        // The org has a pre-existing Case-create automation that requires an
        // unavailable helperConfig parameter.  Use a read-only existing Case
        // as the temporary parent; all links and files created by this test
        // are rolled back by the test transaction.
        Case sourceCase = [SELECT Id FROM Case ORDER BY CreatedDate ASC LIMIT 1];
        Id supportedA = createFile('MULTIDOC-TEST-A', 'pdf');
        Id supportedB = createFile('MULTIDOC-TEST-B', 'jpg');
        Id unsupported = createFile('MULTIDOC-TEST-Case-Note', 'txt');
        linkFile(sourceCase.Id, supportedA);
        linkFile(sourceCase.Id, supportedB);
        linkFile(sourceCase.Id, unsupported);

        RFPExtractionAction.Request allFiles = new RFPExtractionAction.Request();
        allFiles.caseId = sourceCase.Id;
        allFiles.extractionProfileId = profile.Id;
        RecordingInvoker invoker = new RecordingInvoker();
        RFPExtractionQueueable.templateInvoker = invoker;

        Test.startTest();
        List<RFPExtractionAction.Result> allResults = RFPExtractionAction.execute(
            new List<RFPExtractionAction.Request>{allFiles}
        );

        RFPExtractionAction.Request explicit = new RFPExtractionAction.Request();
        explicit.caseId = sourceCase.Id;
        explicit.contentDocumentId = supportedA;
        explicit.extractionProfileId = profile.Id;
        List<RFPExtractionAction.Result> explicitResults = RFPExtractionAction.execute(
            new List<RFPExtractionAction.Request>{explicit}
        );
        Test.stopTest();
        Id allRfpId = allResults[0].rfpId;
        System.assertEquals(2, RFPFileService.getFilesForParent(allRfpId).size());
        Id explicitRfpId = explicitResults[0].rfpId;
        List<RFPFileService.FileInfo> explicitFiles = RFPFileService.getFilesForParent(explicitRfpId);
        System.assertEquals(1, explicitFiles.size());
        System.assertEquals(supportedA, explicitFiles[0].contentDocumentId);
    }

    private static Extraction_Profile__c createProfile() {
        Extraction_Profile__c profile = new Extraction_Profile__c(
            Name = 'MULTIDOC-TEST-Profile',
            Description__c = 'Test profile for record-bound multi-document grounding.',
            Is_Active__c = true,
            Is_Default__c = false
        );
        insert profile;
        return profile;
    }

    private static Extraction_Question__c createQuestion(Extraction_Profile__c profile, String name) {
        Extraction_Question__c question = new Extraction_Question__c(
            Name = name,
            Extraction_Profile__c = profile.Id,
            Question_Text__c = 'What MULTIDOC-TEST evidence is present across all source files?',
            Output_Type__c = 'Text',
            Question_Type__c = 'Extraction',
            Is_Active__c = true,
            Is_Required__c = true,
            Sort_Order__c = 1,
            Category__c = 'MULTIDOC-TEST'
        );
        insert question;
        return question;
    }

    private static RFP__c createRfp(Extraction_Profile__c profile) {
        RFP__c rfp = new RFP__c(
            Status__c = 'Processing',
            Processing_Status__c = 'Running AI',
            Extraction_Profile__c = profile.Id
        );
        insert rfp;
        return rfp;
    }

    private static Id createFile(String title, String extension) {
        String path = title + '.' + extension;
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = path,
            VersionData = Blob.valueOf('%PDF-1.4 MULTIDOC-TEST ' + title + ' %%EOF')
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    private static void linkFile(Id parentId, Id documentId) {
        insert new ContentDocumentLink(
            LinkedEntityId = parentId,
            ContentDocumentId = documentId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
    }
}
