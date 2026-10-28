@IsTest
private class RFPQuestionBuilderControllerTest {

    // The controller runs in user mode, so tests run as a user with the
    // app's permission set, the way real users do. A fresh org (such as a
    // package build org) gives the default test user no access to the
    // app's fields.
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User builder = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'rfp-builder-test-' + System.currentTimeMillis() + '@example.com',
                LastName = 'Builder Test',
                Email = 'rfp-builder-test@example.com',
                Alias = 'rfpbt',
                TimeZoneSidKey = 'Europe/Berlin',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert builder;
            insert new PermissionSetAssignment(
                AssigneeId = builder.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'RFP_Agent' LIMIT 1].Id
            );
        }

        Extraction_Profile__c profile = new Extraction_Profile__c(Name = 'Builder Test', Is_Active__c = true);
        insert profile;
        insert new List<Extraction_Question__c>{
            new Extraction_Question__c(
                Name = 'Deadline', Extraction_Profile__c = profile.Id,
                Question_Text__c = 'When is the deadline?', Question_Type__c = 'Extraction',
                Output_Type__c = 'Date', Category__c = 'Timeline', Sort_Order__c = 10,
                Confidence_Threshold__c = 80
            ),
            new Extraction_Question__c(
                Name = 'Win Themes', Extraction_Profile__c = profile.Id,
                Question_Text__c = 'What should we emphasize?', Question_Type__c = 'Reasoning',
                Output_Type__c = 'Long Text', Category__c = 'Strategy', Sort_Order__c = 20,
                Confidence_Threshold__c = 0
            )
        };
    }

    private static User builderUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'rfp-builder-test-%@example.com' LIMIT 1];
    }

    private static Id profileId() {
        return [SELECT Id FROM Extraction_Profile__c WHERE Name = 'Builder Test' LIMIT 1].Id;
    }

    private static RFPQuestionBuilderController.Question newQuestion(String key, String label) {
        RFPQuestionBuilderController.Question q = new RFPQuestionBuilderController.Question();
        q.clientKey = key;
        q.label = label;
        q.questionText = 'What is the ' + label + '?';
        q.questionType = 'Extraction';
        q.outputType = 'Text';
        q.category = 'General';
        q.isRequired = false;
        q.confidenceThreshold = 75;
        q.sortOrder = 30;
        return q;
    }

    @IsTest
    static void loadsQuestionsInExtractionOrder() {
        System.runAs(builderUser()) {
            RFPQuestionBuilderController.BuilderState state =
                RFPQuestionBuilderController.getBuilderState(profileId());

            Assert.areEqual(2, state.questions.size());
            Assert.areEqual('Win Themes', state.questions[0].label, 'Strategy sorts before Timeline');
            Assert.isTrue(state.starterQuestions.isEmpty(), 'Starters are only offered to empty profiles');
            Assert.isTrue(state.canEdit);
        }
    }

    @IsTest
    static void offersStarterQuestionsForEmptyProfile() {
        System.runAs(builderUser()) {
            Extraction_Profile__c empty = new Extraction_Profile__c(Name = 'Empty', Is_Active__c = true);
            insert empty;

            RFPQuestionBuilderController.BuilderState state =
                RFPQuestionBuilderController.getBuilderState(empty.Id);

            Assert.isTrue(state.questions.isEmpty());
            Assert.areEqual(RFPInstallHandler.starterQuestions(null).size(), state.starterQuestions.size());
            Assert.isNull(state.starterQuestions[0].id, 'Starters are unsaved');
        }
    }

    @IsTest
    static void savesCreateUpdateRetireAndGroundingTogether() {
        System.runAs(builderUser()) {
            Id pid = profileId();
            RFPQuestionBuilderController.BuilderState state = RFPQuestionBuilderController.getBuilderState(pid);
            RFPQuestionBuilderController.Question deadline = state.questions[0];
            RFPQuestionBuilderController.Question winThemes = state.questions[1];
            deadline.clientKey = 'k1';
            deadline.extractionHint = 'Use YYYY-MM-DD.';
            deadline.isRequired = true;

            Test.startTest();
            RFPQuestionBuilderController.SaveResult result = RFPQuestionBuilderController.saveBuilder(
                pid, 'We sell logistics software.', true,
                new List<RFPQuestionBuilderController.Question>{ deadline, newQuestion('k2', 'Budget') },
                new List<Id>{ winThemes.id }
            );
            Test.stopTest();

            Assert.isTrue(result.success, String.valueOf(result.rowErrors));
            Assert.areEqual(2, result.state.questions.size(), 'Retired question drops out, new one appears');
            Assert.areEqual('We sell logistics software.', result.state.groundingContext);

            Extraction_Question__c saved = [
                SELECT Extraction_Hint__c, Is_Required__c FROM Extraction_Question__c WHERE Id = :deadline.id
            ];
            Assert.areEqual('Use YYYY-MM-DD.', saved.Extraction_Hint__c);
            Assert.isTrue(saved.Is_Required__c);
            Assert.isFalse([SELECT Is_Active__c FROM Extraction_Question__c WHERE Id = :winThemes.id].Is_Active__c,
                'Removal is a soft delete');
        }
    }

    @IsTest
    static void reportsRowErrorsWithoutWritingAnything() {
        System.runAs(builderUser()) {
            Id pid = profileId();
            RFPQuestionBuilderController.Question blank = newQuestion('blank', 'Scope');
            blank.questionText = '  ';
            RFPQuestionBuilderController.Question duplicate = newQuestion('dup', 'deadline');
            RFPQuestionBuilderController.Question longLabel = newQuestion('long', 'x'.repeat(81));
            RFPQuestionBuilderController.Question badType = newQuestion('badType', 'Region');
            badType.outputType = 'Spreadsheet';
            RFPQuestionBuilderController.Question threshold = newQuestion('threshold', 'Value');
            threshold.confidenceThreshold = 150;
            RFPQuestionBuilderController.Question valid = newQuestion('valid', 'Valid One');

            RFPQuestionBuilderController.SaveResult result = RFPQuestionBuilderController.saveBuilder(
                pid, 'ignored', true,
                new List<RFPQuestionBuilderController.Question>{ blank, duplicate, longLabel, badType, threshold, valid },
                new List<Id>()
            );

            Assert.isFalse(result.success);
            Assert.areEqual(5, result.rowErrors.size(), String.valueOf(result.rowErrors));
            Assert.isFalse(result.rowErrors.containsKey('valid'));
            Assert.areEqual(2, [SELECT COUNT() FROM Extraction_Question__c WHERE Extraction_Profile__c = :pid]);
            Assert.isNull([SELECT Grounding_Context__c FROM Extraction_Profile__c WHERE Id = :pid].Grounding_Context__c);
        }
    }

    @IsTest
    static void allowsSwappingLabelsBetweenQuestions() {
        System.runAs(builderUser()) {
            Id pid = profileId();
            List<RFPQuestionBuilderController.Question> qs = RFPQuestionBuilderController.getBuilderState(pid).questions;
            qs[0].clientKey = 'a';
            qs[0].label = 'Win Themes';
            qs[1].clientKey = 'b';
            qs[1].label = 'Deadline';

            RFPQuestionBuilderController.SaveResult result =
                RFPQuestionBuilderController.saveBuilder(pid, null, false, qs, null);

            Assert.isTrue(result.success, String.valueOf(result.rowErrors));
        }
    }

    @IsTest
    static void rejectsQuestionsFromAnotherProfile() {
        System.runAs(builderUser()) {
            Extraction_Profile__c other = new Extraction_Profile__c(Name = 'Other', Is_Active__c = true);
            insert other;
            RFPQuestionBuilderController.Question foreign = RFPQuestionBuilderController.getBuilderState(profileId()).questions[0];
            foreign.clientKey = 'f';

            RFPQuestionBuilderController.SaveResult result = RFPQuestionBuilderController.saveBuilder(
                other.Id, null, false, new List<RFPQuestionBuilderController.Question>{ foreign }, null
            );
            Assert.isFalse(result.success);
            Assert.isTrue(result.rowErrors.containsKey('f'));

            try {
                RFPQuestionBuilderController.saveBuilder(other.Id, null, false, null, new List<Id>{ foreign.id });
                Assert.fail('Retiring another profile\'s question must fail');
            } catch (AuraHandledException e) {
                Assert.isTrue(true);
            }
        }
    }
}
