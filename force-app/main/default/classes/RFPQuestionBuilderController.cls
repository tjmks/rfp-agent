/**
 * Backs the rfpQuestionBuilder LWC on the Extraction Profile record page.
 *
 * The builder loads a profile's active questions and grounding context, then
 * saves every change in one call. Saves are all-or-nothing and run in user mode, so CRUD/FLS apply.
 */
public with sharing class RFPQuestionBuilderController {

    private static final String EXTRACTION = 'Extraction';
    private static final String REASONING = 'Reasoning';
    private static final Integer MAX_LABEL_LENGTH = 80;
    private static final Integer MAX_CATEGORY_LENGTH = 255;

    // ── Load ────────────────────────────────────────────────────────────────

    @AuraEnabled
    public static BuilderState getBuilderState(Id profileId) {
        try {
            return loadState(profileId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Save ────────────────────────────────────────────────────────────────

    /**
     * Applies grounding context, new/changed questions and retirements in one
     * transaction. Validation problems come back per row (keyed by clientKey)
     * and nothing is written; DML failures roll everything back.
     */
    @AuraEnabled
    public static SaveResult saveBuilder(
        Id profileId,
        String groundingContext,
        Boolean groundingChanged,
        List<Question> questions,
        List<Id> retireIds
    ) {
        questions = questions ?? new List<Question>();
        retireIds = retireIds ?? new List<Id>();

        Map<Id, Extraction_Question__c> existing = new Map<Id, Extraction_Question__c>([
            SELECT Id, Name FROM Extraction_Question__c
            WHERE Extraction_Profile__c = :profileId AND Is_Active__c = true
            WITH USER_MODE
        ]);

        SaveResult result = new SaveResult();
        result.rowErrors = validate(questions, retireIds, existing);
        if (!result.rowErrors.isEmpty()) {
            result.success = false;
            return result;
        }

        List<Extraction_Question__c> toInsert = new List<Extraction_Question__c>();
        List<Extraction_Question__c> toUpdate = new List<Extraction_Question__c>();
        for (Question q : questions) {
            Extraction_Question__c record = toRecord(q);
            if (q.id == null) {
                record.Extraction_Profile__c = profileId;
                toInsert.add(record);
            } else {
                record.Id = q.id;
                toUpdate.add(record);
            }
        }
        for (Id retireId : retireIds) {
            // Soft delete: historical RFP results keep reading the question live.
            toUpdate.add(new Extraction_Question__c(Id = retireId, Is_Active__c = false));
        }

        Savepoint sp = Database.setSavepoint();
        try {
            if (groundingChanged == true) {
                update as user new Extraction_Profile__c(
                    Id = profileId,
                    Grounding_Context__c = String.isBlank(groundingContext) ? null : groundingContext
                );
            }
            if (!toUpdate.isEmpty()) update as user toUpdate;
            if (!toInsert.isEmpty()) insert as user toInsert;
        } catch (DmlException e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }

        result.success = true;
        result.state = loadState(profileId);
        return result;
    }

    // ── Internals ───────────────────────────────────────────────────────────

    private static BuilderState loadState(Id profileId) {
        Extraction_Profile__c profile = [
            SELECT Id, Grounding_Context__c
            FROM Extraction_Profile__c
            WHERE Id = :profileId
            WITH USER_MODE
            LIMIT 1
        ];

        BuilderState state = new BuilderState();
        state.groundingContext = profile.Grounding_Context__c;
        state.canEdit = Schema.SObjectType.Extraction_Question__c.isCreateable()
            && Schema.SObjectType.Extraction_Question__c.isUpdateable();
        state.questions = new List<Question>();
        // Same order the extraction job sends questions to the AI.
        for (Extraction_Question__c q : [
            SELECT Id, Name, Question_Text__c, Extraction_Hint__c, Question_Type__c,
                   Output_Type__c, Category__c, Is_Required__c, Confidence_Threshold__c,
                   Sort_Order__c
            FROM Extraction_Question__c
            WHERE Extraction_Profile__c = :profileId AND Is_Active__c = true
            WITH USER_MODE
            ORDER BY Category__c ASC NULLS LAST, Sort_Order__c ASC NULLS LAST, CreatedDate ASC
        ]) {
            state.questions.add(fromRecord(q));
        }

        state.starterQuestions = new List<Question>();
        if (state.questions.isEmpty()) {
            for (Extraction_Question__c q : RFPInstallHandler.starterQuestions(null)) {
                state.starterQuestions.add(fromRecord(q));
            }
        }
        return state;
    }

    private static List<String> outputTypes() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : Extraction_Question__c.Output_Type__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) values.add(e.getValue());
        }
        return values;
    }

    private static Map<String, String> validate(
        List<Question> questions, List<Id> retireIds, Map<Id, Extraction_Question__c> existing
    ) {
        Set<Id> ownIds = existing.keySet();
        Map<String, String> errors = new Map<String, String>();
        Set<String> validOutputTypes = new Set<String>(outputTypes());

        for (Id retireId : retireIds) {
            if (!ownIds.contains(retireId)) {
                throw new AuraHandledException('A removed question no longer belongs to this profile. Reload and try again.');
            }
        }

        for (Question q : questions) {
            String error;
            if (q.id != null && !ownIds.contains(q.id)) {
                error = 'This question no longer exists on this profile. Reload the page.';
            } else if (String.isBlank(q.label)) {
                error = 'Add a label.';
            } else if (q.label.trim().length() > MAX_LABEL_LENGTH) {
                error = 'Keep the label to ' + MAX_LABEL_LENGTH + ' characters or fewer.';
            } else if (String.isBlank(q.questionText)) {
                error = 'Add the question the AI should answer.';
            } else if (q.questionType != EXTRACTION && q.questionType != REASONING) {
                error = 'Choose Extraction or Reasoning.';
            } else if (!validOutputTypes.contains(q.outputType)) {
                error = 'Choose an output type.';
            } else if (q.category != null && q.category.trim().length() > MAX_CATEGORY_LENGTH) {
                error = 'Keep the category to ' + MAX_CATEGORY_LENGTH + ' characters or fewer.';
            } else if (q.questionType == EXTRACTION
                && (q.confidenceThreshold == null || q.confidenceThreshold < 0 || q.confidenceThreshold > 100)) {
                error = 'Set a confidence threshold between 0 and 100.';
            }
            if (error != null) errors.put(q.clientKey, error);
        }

        // Labels become result column headers, so they must be unique across
        // the profile: saved questions that aren't being edited or retired
        // count too.
        Set<Id> untouched = new Set<Id>(ownIds);
        untouched.removeAll(retireIds);
        for (Question q : questions) untouched.remove(q.id);
        Set<String> takenLabels = new Set<String>();
        for (Id untouchedId : untouched) {
            takenLabels.add(existing.get(untouchedId).Name.trim().toLowerCase());
        }
        for (Question q : questions) {
            if (String.isBlank(q.label)) continue;
            String key = q.label.trim().toLowerCase();
            if (takenLabels.contains(key) && !errors.containsKey(q.clientKey)) {
                errors.put(q.clientKey, 'Another question already uses this label.');
            }
            takenLabels.add(key);
        }
        return errors;
    }

    private static Extraction_Question__c toRecord(Question q) {
        Boolean isReasoning = q.questionType == REASONING;
        String category = String.isBlank(q.category) ? null : q.category.trim();
        return new Extraction_Question__c(
            Name = q.label.trim(),
            Question_Text__c = q.questionText.trim(),
            Extraction_Hint__c = String.isBlank(q.extractionHint) ? null : q.extractionHint.trim(),
            Question_Type__c = q.questionType,
            Output_Type__c = q.outputType,
            Category__c = category,
            Is_Required__c = q.isRequired == true,
            // Reasoning answers are excluded from confidence filtering; 0 matches the seeded data.
            Confidence_Threshold__c = isReasoning ? 0 : q.confidenceThreshold,
            Sort_Order__c = q.sortOrder
        );
    }

    private static Question fromRecord(Extraction_Question__c q) {
        Question dto = new Question();
        dto.id = q.Id;
        dto.label = q.Name;
        dto.questionText = q.Question_Text__c;
        dto.extractionHint = q.Extraction_Hint__c;
        dto.questionType = q.Question_Type__c ?? EXTRACTION;
        dto.outputType = q.Output_Type__c;
        dto.category = q.Category__c;
        dto.isRequired = q.Is_Required__c == true;
        dto.confidenceThreshold = q.Confidence_Threshold__c;
        dto.sortOrder = q.Sort_Order__c;
        return dto;
    }

    // ── Wrappers ────────────────────────────────────────────────────────────

    public class BuilderState {
        @AuraEnabled public String groundingContext;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public List<Question> questions;
        @AuraEnabled public List<Question> starterQuestions;
    }

    public class SaveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Map<String, String> rowErrors;
        @AuraEnabled public BuilderState state;
    }

    public class Question {
        @AuraEnabled public String clientKey { get; set; }
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String questionText { get; set; }
        @AuraEnabled public String extractionHint { get; set; }
        @AuraEnabled public String questionType { get; set; }
        @AuraEnabled public String outputType { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Boolean isRequired { get; set; }
        @AuraEnabled public Decimal confidenceThreshold { get; set; }
        @AuraEnabled public Decimal sortOrder { get; set; }
    }
}
