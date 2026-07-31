public with sharing class RFPResultParser {

    public static List<Extraction_Result__c> parse(
        Id rfpId,
        String rawResponse,
        List<Extraction_Question__c> questions
    ) {
        Map<String, Extraction_Question__c> questionById = new Map<String, Extraction_Question__c>();
        for (Extraction_Question__c q : questions) {
            questionById.put(q.Id, q);
        }

        String sanitizedJson = sanitizeResponse(rawResponse);

        List<Object> parsed;
        try {
            parsed = (List<Object>) JSON.deserializeUntyped(sanitizedJson);
        } catch (Exception e) {
            throw new RFPExtractionException(
                'Malformed JSON from extraction template. Raw response: ' + rawResponse.left(500)
            );
        }

        List<Extraction_Result__c> results = new List<Extraction_Result__c>();
        for (Object item : parsed) {
            Map<String, Object> entry = (Map<String, Object>) item;

            String qId = (String) entry.get('id');
            Extraction_Question__c q = questionById.get(qId);
            if (q == null) {
                continue;
            }

            Object rawValue = entry.get('value');
            Decimal confidence = null;
            if (entry.get('confidence') != null) {
                confidence = (((Decimal) entry.get('confidence')) * 100).setScale(0);
            }

            results.add(new Extraction_Result__c(
                RFP__c = rfpId,
                Extraction_Question__c = q.Id,
                Field_Label__c = String.isBlank(q.Question_Label__c) ? q.Name : q.Question_Label__c,
                Target_Field_API_Name__c = q.Target_Field_API_Name__c,
                Category__c = q.Category__c,
                Extracted_Value__c = rawValue != null ? valueToString(rawValue) : null,
                Confidence_Score__c = confidence,
                Citation__c = (String) entry.get('citation'),
                Review_Status__c = 'Pending',
                Sort_Order__c = q.Sort_Order__c
            ));
        }
        return results;
    }

    private static String sanitizeResponse(String raw) {
        String s = raw.trim();
        // Strip markdown code fences that models sometimes add
        if (s.startsWith('```')) {
            s = s.replaceAll('(?s)^```[a-z]*\\n?', '').replaceAll('```\\s*$', '').trim();
        }
        return s;
    }

    private static String valueToString(Object val) {
        if (val instanceof List<Object>) {
            return JSON.serialize(val);
        }
        return String.valueOf(val);
    }
}
