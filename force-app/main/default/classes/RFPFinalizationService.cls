public with sharing class RFPFinalizationService {

    // Reserved app-managed control fields that extraction may never populate,
    // regardless of field-set configuration. Defense-in-depth alongside the
    // Extraction_Target_Fields allowlist. Lowercased for case-insensitive match.
    private static final Set<String> RESERVED_FIELDS = new Set<String>{
        'status__c', 'processing_status__c', 'processing_error__c',
        'overall_confidence__c', 'source_document_id__c',
        'extraction_profile__c', 'account__c', 'opportunity__c'
    };

    /**
     * API names of RFP__c fields extraction is permitted to write, sourced from
     * the Extraction_Target_Fields field set so admins can allowlist their own
     * fields with no Apex change. Lowercased for case-insensitive matching.
     */
    private static Set<String> getPermittedTargetFields() {
        Set<String> permitted = new Set<String>();
        Schema.FieldSet fs =
            Schema.SObjectType.RFP__c.fieldSets.getMap().get('Extraction_Target_Fields');
        if (fs == null) {
            return permitted;
        }
        for (Schema.FieldSetMember member : fs.getFields()) {
            permitted.add(member.getFieldPath().toLowerCase());
        }
        return permitted;
    }

    public static void finalize(Id rfpId) {
        RFP__c rfp = [
            SELECT Id, Extraction_Profile__c
            FROM RFP__c
            WHERE Id = :rfpId

            LIMIT 1
        ];

        validateRequiredFields(rfpId, rfp.Extraction_Profile__c);

        List<Extraction_Result__c> accepted = [
            SELECT Id, Target_Field_API_Name__c, Extracted_Value__c,
                   Accepted_Value__c, Review_Status__c
            FROM Extraction_Result__c
            WHERE RFP__c = :rfpId
              AND Review_Status__c IN ('Accepted', 'Edited')
              AND Target_Field_API_Name__c != null

        ];

        Map<String, Schema.SObjectField> fieldMap =
            Schema.SObjectType.RFP__c.fields.getMap();
        Set<String> permittedFields = getPermittedTargetFields();

        RFP__c rfpToUpdate = new RFP__c(Id = rfpId);
        List<String> coercionErrors = new List<String>();

        for (Extraction_Result__c result : accepted) {
            String apiName = result.Target_Field_API_Name__c.toLowerCase();
            Schema.SObjectField sField = fieldMap.get(apiName);
            if (sField == null) {
                continue;
            }

            // Reserved app-managed fields are never writable by extraction,
            // even if mistakenly added to the field set.
            if (RESERVED_FIELDS.contains(apiName)) {
                coercionErrors.add(
                    result.Target_Field_API_Name__c
                        + ': reserved field cannot be an extraction target'
                );
                continue;
            }

            // Allowlist: the target must be explicitly permitted via the
            // Extraction_Target_Fields field set. This bounds dynamic writes to
            // fields an admin has deliberately opted in, regardless of the
            // running user's broad update permissions.
            if (!permittedFields.contains(apiName)) {
                coercionErrors.add(
                    result.Target_Field_API_Name__c
                        + ': not in the Extraction Target Fields allowlist'
                );
                continue;
            }

            // Enforce FLS: only write fields the running user may update.
            if (!sField.getDescribe().isUpdateable()) {
                coercionErrors.add(
                    result.Target_Field_API_Name__c
                        + ': field is not updateable for the current user'
                );
                continue;
            }

            String value = result.Review_Status__c == 'Edited'
                ? result.Accepted_Value__c
                : result.Extracted_Value__c;

            try {
                Object coerced = coerce(value, sField.getDescribe().getType());
                rfpToUpdate.put(sField, coerced);
            } catch (Exception e) {
                coercionErrors.add(
                    result.Target_Field_API_Name__c + ': ' + e.getMessage()
                );
            }
        }

        if (!coercionErrors.isEmpty()) {
            throw new RFPExtractionException(
                'Value conversion failed for: ' + String.join(coercionErrors, ', ')
            );
        }

        rfpToUpdate.Status__c = 'Approved';
        rfpToUpdate.Processing_Status__c = 'Complete';
        update rfpToUpdate;
    }

    private static void validateRequiredFields(Id rfpId, Id profileId) {
        Set<Id> requiredQuestionIds = new Set<Id>();
        for (Extraction_Question__c q : [
            SELECT Id
            FROM Extraction_Question__c
            WHERE Extraction_Profile__c = :profileId
              AND Is_Required__c = true

        ]) {
            requiredQuestionIds.add(q.Id);
        }

        if (requiredQuestionIds.isEmpty()) {
            return;
        }

        List<Extraction_Result__c> unresolved = [
            SELECT Field_Label__c
            FROM Extraction_Result__c
            WHERE RFP__c = :rfpId
              AND Extraction_Question__c IN :requiredQuestionIds
              AND Review_Status__c = 'Pending'

        ];

        if (!unresolved.isEmpty()) {
            List<String> labels = new List<String>();
            for (Extraction_Result__c r : unresolved) {
                labels.add(r.Field_Label__c);
            }
            throw new RFPExtractionException(
                'Required fields not yet reviewed: ' + String.join(labels, ', ')
            );
        }
    }

    private static Object coerce(String value, Schema.DisplayType dtype) {
        if (String.isBlank(value)) {
            return null;
        }
        if (dtype == Schema.DisplayType.DATE) {
            return Date.valueOf(value.left(10));
        }
        if (dtype == Schema.DisplayType.DATETIME) {
            return DateTime.valueOf(value.replace('T', ' ').left(19));
        }
        if (dtype == Schema.DisplayType.DOUBLE
            || dtype == Schema.DisplayType.CURRENCY
            || dtype == Schema.DisplayType.PERCENT) {
            return Decimal.valueOf(value.replaceAll('[^0-9.]', ''));
        }
        if (dtype == Schema.DisplayType.INTEGER) {
            return Integer.valueOf(value.replaceAll('[^0-9]', ''));
        }
        if (dtype == Schema.DisplayType.BOOLEAN) {
            return value.toLowerCase() == 'true';
        }
        return value;
    }
}
