@IsTest
private class RFPInstallHandlerTest {

    @IsTest
    static void seedsDefaultProfileOnFreshInstall() {
        Test.startTest();
        Test.testInstall(new RFPInstallHandler(), null);
        Test.stopTest();

        List<Extraction_Profile__c> profiles = [
            SELECT Id, Is_Default__c, Is_Active__c
            FROM Extraction_Profile__c
            WHERE Name = 'Default RFP'
        ];
        System.assertEquals(1, profiles.size(), 'Fresh install should seed one Default RFP profile');
        System.assertEquals(true, profiles[0].Is_Default__c, 'Seeded profile should be default');

        Integer questionCount = [
            SELECT COUNT()
            FROM Extraction_Question__c
            WHERE Extraction_Profile__c = :profiles[0].Id
        ];
        System.assertEquals(9, questionCount, 'Seeded profile should have 9 questions');
    }

    @IsTest
    static void seedsOnFirstUseOnlyWhenNoProfilesExist() {
        Assert.isTrue(RFPController.ensureStarterProfile(), 'An org with no profiles gets the starter one');
        Assert.areEqual(9, [SELECT COUNT() FROM Extraction_Question__c]);
        Assert.isFalse(RFPController.ensureStarterProfile(), 'Seeding happens only once');
        Assert.areEqual(1, [SELECT COUNT() FROM Extraction_Profile__c]);
    }

    @IsTest
    static void isNonDestructiveWhenProfileAlreadyExists() {
        insert new Extraction_Profile__c(
            Name = 'Default RFP',
            Is_Active__c = true,
            Is_Default__c = true
        );

        Test.startTest();
        // Simulates an upgrade: profile already present, so nothing new is seeded.
        Test.testInstall(new RFPInstallHandler(), new Version(1, 0));
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Extraction_Profile__c WHERE Name = 'Default RFP'],
            'Existing profile must not be duplicated on upgrade'
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Extraction_Question__c],
            'Non-destructive handler must not add questions when profile already exists'
        );
    }
}
