// Seeds (or refreshes) the "Default RFP" Extraction Profile and its questions.
// Idempotent: re-running deletes the profile's existing questions and reinserts them.

String PROFILE_NAME = 'Default RFP';

Extraction_Profile__c profile;
List<Extraction_Profile__c> existing = [
    SELECT Id FROM Extraction_Profile__c WHERE Name = :PROFILE_NAME LIMIT 1
];
if (existing.isEmpty()) {
    profile = new Extraction_Profile__c(
        Name = PROFILE_NAME,
        Description__c = 'Out-of-the-box starter profile covering generic fields and analysis',
        Is_Active__c = true,
        Is_Default__c = true
    );
    insert profile;
} else {
    profile = existing[0];
    profile.Description__c = 'Out-of-the-box starter profile covering generic fields and analysis';
    profile.Is_Active__c = true;
    profile.Is_Default__c = true;
    update profile;

    delete [SELECT Id FROM Extraction_Question__c WHERE Extraction_Profile__c = :profile.Id];
}

List<Extraction_Question__c> questions = new List<Extraction_Question__c>();

// ── Extraction questions ─────────────────────────────────────────────────
questions.add(new Extraction_Question__c(
    Name = 'Project Title',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'What is the official title or name of the project, program, or solicitation being requested?',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'Text',
    Category__c = 'Overview',
    Sort_Order__c = 10,
    Is_Active__c = true,
    Is_Required__c = true,
    Confidence_Threshold__c = 70
));

questions.add(new Extraction_Question__c(
    Name = 'Issuing Organization',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'What is the name of the organization, agency, or company issuing this RFP?',
    Extraction_Hint__c = 'Look on the cover page, header, or "About Us" section. Return only the legal entity name.',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'Text',
    Category__c = 'Overview',
    Sort_Order__c = 20,
    Is_Active__c = true,
    Is_Required__c = true,
    Confidence_Threshold__c = 80
));

questions.add(new Extraction_Question__c(
    Name = 'Submission Deadline',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'What is the deadline for submitting proposals in response to this RFP? Return a single date (the latest hard cutoff if multiple are given).',
    Extraction_Hint__c = 'Use ISO format YYYY-MM-DD. If only a relative date is given (e.g. "30 days after issue"), leave the value empty and lower confidence.',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'Date',
    Category__c = 'Timeline',
    Sort_Order__c = 30,
    Is_Active__c = true,
    Is_Required__c = true,
    Confidence_Threshold__c = 80
));

questions.add(new Extraction_Question__c(
    Name = 'Estimated Contract Value',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'What is the estimated total contract value, budget ceiling, or expected spend for this engagement?',
    Extraction_Hint__c = 'If a range is given, return the upper bound. If no monetary value is stated, leave empty and set confidence to 0.',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'Currency',
    Category__c = 'Commercial',
    Sort_Order__c = 40,
    Is_Active__c = true,
    Is_Required__c = false,
    Confidence_Threshold__c = 60
));

questions.add(new Extraction_Question__c(
    Name = 'Required Capabilities',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'List the core capabilities, services, or product categories the responding vendor must provide.',
    Extraction_Hint__c = 'Return a concise list (typically 3-10 items). Prefer the document\'s own phrasing.',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'List',
    Category__c = 'Scope',
    Sort_Order__c = 50,
    Is_Active__c = true,
    Is_Required__c = true,
    Confidence_Threshold__c = 70
));

questions.add(new Extraction_Question__c(
    Name = 'Primary Contact',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'Who are the points of contact for questions and submissions? Return all contacts listed, including name, title, and email where available. Format each as "Name, Title — email" on a separate line.',
    Extraction_Hint__c = 'Include all contacts mentioned for proposal submission, technical questions, or general inquiries — do not limit to one.',
    Question_Type__c = 'Extraction',
    Output_Type__c = 'Text',
    Category__c = 'Contacts',
    Sort_Order__c = 60,
    Is_Active__c = true,
    Is_Required__c = false,
    Confidence_Threshold__c = 70
));

// ── Reasoning questions (250-word cap baked into each prompt) ────────────
String wordCap = '\n\nLimit your answer to 250 words or fewer.';

questions.add(new Extraction_Question__c(
    Name = 'Win Themes',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'Based on the priorities, evaluation criteria, and pain points expressed in this RFP, what 3-5 win themes should our response emphasize? For each theme, name a specific passage or requirement from the document that supports it.' + wordCap,
    Question_Type__c = 'Reasoning',
    Output_Type__c = 'Long Text',
    Category__c = 'Strategy',
    Sort_Order__c = 110,
    Is_Active__c = true,
    Is_Required__c = false,
    Confidence_Threshold__c = 0
));

questions.add(new Extraction_Question__c(
    Name = 'Risks and Gaps',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'What are the most significant risks, capability gaps, or red flags in this RFP for our company? Consider scope ambiguity, unrealistic timelines, onerous terms, mandatory certifications, and any requirements that may be hard for us to meet.' + wordCap,
    Question_Type__c = 'Reasoning',
    Output_Type__c = 'Long Text',
    Category__c = 'Strategy',
    Sort_Order__c = 120,
    Is_Active__c = true,
    Is_Required__c = false,
    Confidence_Threshold__c = 0
));

questions.add(new Extraction_Question__c(
    Name = 'Go / No-Go Recommendation',
    Extraction_Profile__c = profile.Id,
    Question_Text__c = 'Should we pursue this RFP? Give a clear Go, No-Go, or Conditional Go recommendation, then explain the reasoning by weighing fit, win probability, effort to respond, and strategic value. If Conditional, name the conditions that must be true to proceed.' + wordCap,
    Question_Type__c = 'Reasoning',
    Output_Type__c = 'Long Text',
    Category__c = 'Strategy',
    Sort_Order__c = 130,
    Is_Active__c = true,
    Is_Required__c = false,
    Confidence_Threshold__c = 0
));

insert questions;

System.debug('Seeded profile ' + profile.Id + ' with ' + questions.size() + ' questions.');
