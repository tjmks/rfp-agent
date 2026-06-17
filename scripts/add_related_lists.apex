// Adds Extraction Results to RFP layout and Extraction Questions + RFPs to
// Extraction Profile layout via Metadata API callout from Apex.
// Safe to re-run — reads the current layout and skips if already present.

List<String> errors = new List<String>();

// ── RFP Layout: add Extraction_Results ──────────────────────────────────────
MetadataService.MetadataPort port = new MetadataService.MetadataPort();
port.SessionHeader = new MetadataService.SessionHeader_element();
port.SessionHeader.sessionId = UserInfo.getSessionId();
port.CallOptions = new MetadataService.CallOptions_element();
port.CallOptions.client = 'RFPAgent';

MetadataService.Layout rfpLayout = (MetadataService.Layout)
    port.readMetadata('Layout', new List<String>{'RFP__c-RFP Layout'})[0];

Boolean hasExtractionResults = false;
if (rfpLayout.relatedLists != null) {
    for (MetadataService.RelatedListItem rli : rfpLayout.relatedLists) {
        if (rli.relatedList == 'Extraction_Results') { hasExtractionResults = true; break; }
    }
}
if (!hasExtractionResults) {
    MetadataService.RelatedListItem rli = new MetadataService.RelatedListItem();
    rli.relatedList = 'Extraction_Results';
    rli.fields = new List<String>{
        'Field_Label__c', 'Extracted_Value__c', 'Accepted_Value__c',
        'Confidence_Score__c', 'Review_Status__c', 'Category__c'
    };
    if (rfpLayout.relatedLists == null) rfpLayout.relatedLists = new List<MetadataService.RelatedListItem>();
    rfpLayout.relatedLists.add(rli);
    List<MetadataService.SaveResult> results = port.updateMetadata(new List<MetadataService.Metadata>{ rfpLayout });
    if (!results[0].success) errors.add('RFP Layout: ' + results[0].errors[0].message);
    else System.debug('Added Extraction_Results to RFP Layout');
} else {
    System.debug('Extraction_Results already on RFP Layout - skipping');
}

// ── Extraction Profile Layout: add Extraction_Questions + RFPs ──────────────
MetadataService.Layout profLayout = (MetadataService.Layout)
    port.readMetadata('Layout', new List<String>{'Extraction_Profile__c-Extraction Profile Layout'})[0];

Boolean hasQuestions = false, hasRFPs = false;
if (profLayout.relatedLists != null) {
    for (MetadataService.RelatedListItem rli : profLayout.relatedLists) {
        if (rli.relatedList == 'Extraction_Questions') hasQuestions = true;
        if (rli.relatedList == 'RFPs') hasRFPs = true;
    }
}
Boolean profChanged = false;
if (!hasQuestions) {
    MetadataService.RelatedListItem rli = new MetadataService.RelatedListItem();
    rli.relatedList = 'Extraction_Questions';
    rli.fields = new List<String>{
        'Name', 'Question_Text__c', 'Output_Type__c',
        'Question_Type__c', 'Category__c', 'Is_Required__c', 'Sort_Order__c', 'Is_Active__c'
    };
    if (profLayout.relatedLists == null) profLayout.relatedLists = new List<MetadataService.RelatedListItem>();
    profLayout.relatedLists.add(rli);
    profChanged = true;
}
if (!hasRFPs) {
    MetadataService.RelatedListItem rli = new MetadataService.RelatedListItem();
    rli.relatedList = 'RFPs';
    rli.fields = new List<String>{
        'Name', 'Status__c', 'Account__c', 'Overall_Confidence__c', 'Processing_Status__c'
    };
    if (profLayout.relatedLists == null) profLayout.relatedLists = new List<MetadataService.RelatedListItem>();
    profLayout.relatedLists.add(rli);
    profChanged = true;
}
if (profChanged) {
    List<MetadataService.SaveResult> results = port.updateMetadata(new List<MetadataService.Metadata>{ profLayout });
    if (!results[0].success) errors.add('Profile Layout: ' + results[0].errors[0].message);
    else System.debug('Updated Extraction Profile Layout');
} else {
    System.debug('Extraction Profile Layout already has all related lists - skipping');
}

if (!errors.isEmpty()) System.debug('ERRORS: ' + String.join(errors, ' | '));
else System.debug('Done.');
