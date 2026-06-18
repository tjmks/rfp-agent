import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, updateRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import GROUNDING_CONTEXT_FIELD from '@salesforce/schema/Extraction_Profile__c.Grounding_Context__c';
import getExistingQuestions from '@salesforce/apex/RFPController.getExistingQuestions';
import createQuestions from '@salesforce/apex/RFPController.createQuestions';
import updateQuestions from '@salesforce/apex/RFPController.updateQuestions';
import deleteQuestions from '@salesforce/apex/RFPController.deleteQuestions';

const TYPE_OPTIONS = [
    { label: 'Text', value: 'Text' },
    { label: 'Long Text', value: 'Long Text' },
    { label: 'Number', value: 'Number' },
    { label: 'Date', value: 'Date' },
    { label: 'Currency', value: 'Currency' },
    { label: 'Boolean', value: 'Boolean' },
    { label: 'List', value: 'List' }
];

const QUESTION_TYPE_OPTIONS = [
    { label: 'Extraction', value: 'Extraction' },
    { label: 'Reasoning', value: 'Reasoning' }
];

const DEFAULT_CATEGORIES = ['General', 'Commercial', 'Technical', 'Compliance'];

const HELP = {
    questionLabel: 'A short, human-readable name for this field. Appears as the column header in extraction results. Keep it under ~30 characters. Example: "Submission Deadline".',
    questionPrompt: 'The natural-language question the AI will answer. Be specific and include format hints. Example: "What is the deadline for submitting the proposal? Return as YYYY-MM-DD."',
    questionType: 'Routes the question to a different AI prompt.\n\nExtraction — best when the answer appears directly in the document (deadlines, prices, named entities, contacts). Returns a confidence score per answer and contributes to the overall RFP confidence rollup.\n\nReasoning — best when the answer requires synthesis across multiple sections (scope summaries, fit assessments, derived implications, comparisons). Runs on a separate template; confidence is fuzzy and excluded from the rollup.',
    outputType: 'How the answer should be formatted. Text/Long Text for free-form. Number/Currency/Date for typed values (validated). Boolean for yes/no. List for multi-value answers.',
    category: 'Groups this question in the review screen (Commercial / Technical / Compliance / General). Purely organizational — it does not change how the AI answers.',
    required: 'When checked, RFP processing flags missing answers for review. Optional questions return null silently if no answer is found.',
    confidenceThreshold: 'Minimum confidence score (0–100) the AI must report for an extracted answer to be considered high-confidence. Answers below this value appear in the Low Confidence filter for human review. Defaults to 80. Not applied to Reasoning questions.'
};

const ACC_ITEM_BASE = 'acc-item';

let _seq = 1;

function makeRow(overrides = {}) {
    const row = {
        id: String(_seq++),
        sfId: null,
        questionLabel: '',
        questionText: '',
        outputType: 'Text',
        questionType: 'Extraction',
        category: 'General',
        isRequired: false,
        confidenceThreshold: 80,
        expanded: false,
        error: null,
        dirty: false,
        markedForDeletion: false,
        ...overrides
    };
    return decorate(row);
}

function decorate(row) {
    const typeClass = row.questionType === 'Reasoning' ? 'acc-item_reasoning' : 'acc-item_extraction';
    const mods = [];
    if (row.markedForDeletion) mods.push('acc-item_pending-delete');
    else {
        if (row.error) mods.push('acc-item_error');
        if (row.sfId && row.dirty) mods.push('acc-item_dirty');
    }
    const rowClass = `${ACC_ITEM_BASE} ${typeClass}${mods.length ? ' ' + mods.join(' ') : ''}`;
    const chevronIcon = row.expanded ? 'utility:chevrondown' : 'utility:chevronright';
    const chevronTitle = row.expanded ? 'Collapse' : 'Expand';
    const isReasoning = row.questionType === 'Reasoning';
    const typeColClass = isReasoning ? 'slds-col slds-size_1-of-2' : 'slds-col slds-size_1-of-3';

    const metaLine1 = `${row.questionType} · ${row.outputType}`;
    const metaLine1Class = `acc-meta-line acc-meta-line_type-${row.questionType.toLowerCase()}`;
    const line2Parts = [];
    if (!isReasoning) line2Parts.push(`${row.confidenceThreshold}%`);
    if (row.isRequired) line2Parts.push('Required');
    const metaLine2 = line2Parts.join(' · ');
    const metaLine2Class = `acc-meta-line acc-meta-line_sub${row.isRequired ? ' acc-meta-line_required' : ''}`;

    return { ...row, rowClass, chevronIcon, chevronTitle, isReasoning, typeColClass, metaLine1, metaLine1Class, metaLine2, metaLine2Class };
}

export default class RfpQuestionBuilder extends LightningElement {
    @api recordId;

    @track rows = [];
    @track isBusy = false;
    @track globalError = null;
    @track pendingNewCategory = null;
    @track categoryList = [...DEFAULT_CATEGORIES];

    @track groundingContext = '';
    @track groundingSaving = false;
    @track groundingSavedLabel = null;
    _groundingTimer = null;

    typeOptions = TYPE_OPTIONS;
    questionTypeOptions = QUESTION_TYPE_OPTIONS;

    helpQuestionLabel = HELP.questionLabel;
    helpQuestionPrompt = HELP.questionPrompt;
    helpQuestionType = HELP.questionType;
    helpOutputType = HELP.outputType;
    helpCategory = HELP.category;
    helpRequired = HELP.required;
    helpConfidenceThreshold = HELP.confidenceThreshold;

    _originalOrder = new Map();
    _dragSourceId = null;

    @wire(getRecord, { recordId: '$recordId', fields: [GROUNDING_CONTEXT_FIELD] })
    wiredProfile({ data }) {
        if (data) {
            this.groundingContext = getFieldValue(data, GROUNDING_CONTEXT_FIELD) || '';
        }
    }

    @wire(getExistingQuestions, { profileId: '$recordId' })
    wiredQuestions({ data }) {
        if (data) {
            this._originalOrder = new Map();
            this.mergeCategories(data.map(q => q.Category__c));
            this.rows = data.map((q, idx) => {
                this._originalOrder.set(q.Id, idx);
                return makeRow({
                    sfId: q.Id,
                    questionLabel: q.Name || '',
                    questionText: q.Question_Text__c || '',
                    outputType: q.Output_Type__c || 'Text',
                    questionType: q.Question_Type__c || 'Extraction',
                    category: q.Category__c || 'General',
                    isRequired: q.Is_Required__c || false,
                    confidenceThreshold: q.Confidence_Threshold__c ?? 80,
                    dirty: false
                });
            });
        }
    }

    // ── Derived state ──────────────────────────────────────────────────────

    get totalCount() {
        return this.rows.filter(r => !r.markedForDeletion).length;
    }

    get requiredCount() {
        return this.rows.filter(r => !r.markedForDeletion && r.isRequired).length;
    }

    get optionalCount() {
        return this.totalCount - this.requiredCount;
    }

    get summaryLabel() {
        const total = this.totalCount;
        if (total === 0) return 'No questions yet';
        return `${total} question${total === 1 ? '' : 's'} · ${this.requiredCount} required · ${this.optionalCount} optional`;
    }

    get hasRows() {
        return this.totalCount > 0;
    }

    // ── Categories ─────────────────────────────────────────────────────────

    mergeCategories(values) {
        const next = [...this.categoryList];
        const lower = new Set(next.map(c => c.toLowerCase()));
        (values || []).forEach(v => {
            const name = (v || '').trim();
            if (name && !lower.has(name.toLowerCase())) {
                next.push(name);
                lower.add(name.toLowerCase());
            }
        });
        this.categoryList = next;
    }

    // ── Category-grouped accordion ─────────────────────────────────────────

    get categoryGroups() {
        const groups = [];
        const byCat = new Map();
        for (const r of this.rows) {
            const cat = (r.category && r.category.trim()) || 'General';
            if (!byCat.has(cat)) {
                const g = { key: cat, category: cat, items: [] };
                byCat.set(cat, g);
                groups.push(g);
            }
            byCat.get(cat).items.push({
                ...r,
                isExisting: !!r.sfId,
                showActiveBody: !r.markedForDeletion
            });
        }
        groups.sort((a, b) => {
            if (a.category === 'General') return -1;
            if (b.category === 'General') return 1;
            return a.category.toLowerCase().localeCompare(b.category.toLowerCase());
        });
        return groups;
    }

    get isAddingCategory() {
        return this.pendingNewCategory !== null;
    }

    get allExpanded() {
        const active = this.rows.filter(r => !r.markedForDeletion);
        return active.length > 0 && active.every(r => r.expanded);
    }

    get allCollapsed() {
        const active = this.rows.filter(r => !r.markedForDeletion);
        return active.length > 0 && active.every(r => !r.expanded);
    }

    // ── Expand / Collapse ──────────────────────────────────────────────────

    handleToggleExpand(event) {
        const { id } = event.currentTarget.dataset;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, expanded: !r.expanded }) : r
        );
    }

    handleExpandAll() {
        this.rows = this.rows.map(r => decorate({ ...r, expanded: true }));
    }

    handleCollapseAll() {
        this.rows = this.rows.map(r => decorate({ ...r, expanded: false }));
    }

    // ── Add Category ───────────────────────────────────────────────────────

    handleAddCategory() {
        this.pendingNewCategory = '';
    }

    handleNewCategoryNameInput(event) {
        this.pendingNewCategory = event.target.value;
    }

    confirmAddCategory() {
        const name = (this.pendingNewCategory || '').trim();
        if (!name) {
            this.pendingNewCategory = null;
            return;
        }
        const existing = this.categoryList.find(c => c.toLowerCase() === name.toLowerCase());
        const finalName = existing || name;
        if (!existing) {
            this.mergeCategories([finalName]);
        }
        this.addQuestionToCategory(finalName);
        this.pendingNewCategory = null;
    }

    cancelAddCategory() {
        this.pendingNewCategory = null;
    }

    // ── Add Question ───────────────────────────────────────────────────────

    handleAddQuestionToCategory(event) {
        const category = event.currentTarget.dataset.category;
        this.addQuestionToCategory(category);
    }

    addQuestionToCategory(category) {
        const newRow = makeRow({ category, expanded: true });
        this.rows = [...this.rows, newRow];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const input = this.template.querySelector(
                `lightning-input[data-id="${newRow.id}"][data-field="questionLabel"]`
            );
            if (input) input.focus();
        }, 50);
    }

    addQuestion() {
        this.addQuestionToCategory('General');
    }

    // ── Grounding context auto-save ────────────────────────────────────────

    handleGroundingChange(event) {
        this.groundingContext = event.target.value;
        clearTimeout(this._groundingTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._groundingTimer = setTimeout(() => {
            this._saveGrounding();
        }, 800);
    }

    async _saveGrounding() {
        this.groundingSaving = true;
        this.groundingSavedLabel = null;
        try {
            await updateRecord({
                fields: {
                    Id: this.recordId,
                    Grounding_Context__c: this.groundingContext
                }
            });
            this.groundingSavedLabel = '• Saved';
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => { this.groundingSavedLabel = null; }, 2000);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error saving context',
                message: e?.body?.message ?? 'Save failed.',
                variant: 'error'
            }));
        } finally {
            this.groundingSaving = false;
        }
    }

    // ── Row mutation helpers ───────────────────────────────────────────────

    _patchRow(id, patch) {
        this.rows = this.rows.map(r =>
            r.id === id
                ? decorate({ ...r, ...patch, dirty: r.sfId ? true : r.dirty, error: null })
                : r
        );
        this.globalError = null;
    }

    handleFieldChange(event) {
        const { id, field } = event.currentTarget.dataset;
        this._patchRow(id, { [field]: event.target.value });
    }

    handleRequiredChange(event) {
        const { id } = event.currentTarget.dataset;
        this._patchRow(id, { isRequired: event.target.checked });
    }

    duplicateRow(event) {
        const { id } = event.currentTarget.dataset;
        const idx = this.rows.findIndex(r => r.id === id);
        if (idx < 0) return;
        const src = this.rows[idx];
        const clone = makeRow({
            questionLabel: src.questionLabel ? `${src.questionLabel} (copy)` : '',
            questionText: src.questionText,
            outputType: src.outputType,
            questionType: src.questionType,
            category: src.category,
            isRequired: src.isRequired,
            confidenceThreshold: src.confidenceThreshold,
            expanded: true
        });
        const next = [...this.rows];
        next.splice(idx + 1, 0, clone);
        this.rows = next;
    }

    deleteRow(event) {
        const { id } = event.currentTarget.dataset;
        if (!this.rows.find(r => r.id === id)) return;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, markedForDeletion: true }) : r
        );
    }

    undoDelete(event) {
        const { id } = event.currentTarget.dataset;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, markedForDeletion: false }) : r
        );
    }

    // ── Drag and drop ──────────────────────────────────────────────────────

    onDragStart(event) {
        const id = event.currentTarget.dataset.id;
        this._dragSourceId = id;
        event.dataTransfer.effectAllowed = 'move';
        try { event.dataTransfer.setData('text/plain', id); } catch (e) { /* ignore */ }
        event.currentTarget.classList.add('acc-item_dragging');
    }

    onDragEnd(event) {
        event.currentTarget.classList.remove('acc-item_dragging');
        this.template.querySelectorAll('.acc-item_drop-target').forEach(el =>
            el.classList.remove('acc-item_drop-target')
        );
        this._dragSourceId = null;
    }

    onDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
    }

    onDragEnter(event) {
        if (!this._dragSourceId) return;
        const targetId = event.currentTarget.dataset.id;
        if (targetId === this._dragSourceId) return;
        const src = this.rows.find(r => r.id === this._dragSourceId);
        const tgt = this.rows.find(r => r.id === targetId);
        if (!src || !tgt) return;
        event.currentTarget.classList.add('acc-item_drop-target');
    }

    onDragLeave(event) {
        event.currentTarget.classList.remove('acc-item_drop-target');
    }

    onDrop(event) {
        event.preventDefault();
        const targetId = event.currentTarget.dataset.id;
        const sourceId = this._dragSourceId;
        event.currentTarget.classList.remove('acc-item_drop-target');
        if (!sourceId || sourceId === targetId) return;

        const src = this.rows.find(r => r.id === sourceId);
        const tgt = this.rows.find(r => r.id === targetId);
        if (!src || !tgt) return;

        const srcIdx = this.rows.indexOf(src);
        const tgtIdx = this.rows.indexOf(tgt);
        let next = [...this.rows];
        const [moved] = next.splice(srcIdx, 1);
        next.splice(tgtIdx, 0, moved);
        if (src.category !== tgt.category) {
            next = next.map(r =>
                r.id === moved.id
                    ? decorate({ ...r, category: tgt.category, dirty: r.sfId ? true : r.dirty })
                    : r
            );
        }
        this.rows = next;
    }

    // ── Save ───────────────────────────────────────────────────────────────

    get newRowsToCreate() {
        return this.rows.filter(r =>
            !r.sfId && !r.markedForDeletion &&
            r.questionLabel?.trim() && r.questionText?.trim()
        );
    }

    get existingRowsToUpdate() {
        return this.rows.filter((r, i) => {
            if (!r.sfId || r.markedForDeletion) return false;
            const moved = this._originalOrder.get(r.sfId) !== i;
            return r.dirty || moved;
        });
    }

    get rowsToDelete() {
        return this.rows.filter(r => r.sfId && r.markedForDeletion);
    }

    get saveDisabled() {
        return this.isBusy ||
            (this.newRowsToCreate.length === 0 &&
             this.existingRowsToUpdate.length === 0 &&
             this.rowsToDelete.length === 0);
    }

    get saveLabel() {
        const parts = [];
        const a = this.newRowsToCreate.length;
        const u = this.existingRowsToUpdate.length;
        const d = this.rowsToDelete.length;
        if (a) parts.push(`Add ${a}`);
        if (u) parts.push(`Update ${u}`);
        if (d) parts.push(`Deactivate ${d}`);
        return parts.length ? parts.join(' / ') : 'Save Questions';
    }

    async handleSave() {
        let hasRowErrors = false;
        const validated = this.rows.map(r => {
            if (r.sfId || r.markedForDeletion) return r;
            const hasLabel = !!r.questionLabel?.trim();
            const hasText = !!r.questionText?.trim();
            if (hasLabel && !hasText) {
                hasRowErrors = true;
                return decorate({ ...r, error: 'Question prompt is required.', expanded: true });
            }
            if (!hasLabel && hasText) {
                hasRowErrors = true;
                return decorate({ ...r, error: 'Label is required.', expanded: true });
            }
            return decorate({ ...r, error: null });
        });
        this.rows = validated;
        if (hasRowErrors) return;

        const toCreate = this.newRowsToCreate;
        const toUpdate = this.existingRowsToUpdate;
        const toDelete = this.rowsToDelete;

        if (toCreate.length === 0 && toUpdate.length === 0 && toDelete.length === 0) {
            this.globalError = 'No changes to save.';
            return;
        }

        const liveRows = this.rows.filter(r => !r.markedForDeletion);
        const sortOrderById = new Map();
        liveRows.forEach((r, idx) => sortOrderById.set(r.id, (idx + 1) * 10));

        this.isBusy = true;
        this.globalError = null;

        try {
            if (toDelete.length > 0) {
                await deleteQuestions({ questionIds: toDelete.map(r => r.sfId) });
            }

            if (toUpdate.length > 0) {
                const payload = toUpdate.map(r => ({
                    id: r.sfId,
                    questionLabel: r.questionLabel.trim(),
                    questionText: r.questionText.trim(),
                    outputType: r.outputType,
                    questionType: r.questionType,
                    category: r.category,
                    isRequired: r.isRequired,
                    sortOrder: sortOrderById.get(r.id),
                    confidenceThreshold: r.questionType === 'Reasoning' ? null : (r.confidenceThreshold ?? 80)
                }));
                await updateQuestions({ questionsJson: JSON.stringify(payload) });
            }

            if (toCreate.length > 0) {
                const payload = toCreate.map(r => ({
                    questionLabel: r.questionLabel.trim(),
                    questionText: r.questionText.trim(),
                    outputType: r.outputType,
                    questionType: r.questionType,
                    category: r.category,
                    isRequired: r.isRequired,
                    sortOrder: sortOrderById.get(r.id),
                    confidenceThreshold: r.questionType === 'Reasoning' ? null : (r.confidenceThreshold ?? 80)
                }));
                await createQuestions({
                    profileId: this.recordId,
                    questionsJson: JSON.stringify(payload)
                });
            }

            const parts = [];
            if (toCreate.length) parts.push(`${toCreate.length} added`);
            if (toUpdate.length) parts.push(`${toUpdate.length} updated`);
            if (toDelete.length) parts.push(`${toDelete.length} deactivated`);

            this.dispatchEvent(new ShowToastEvent({
                title: 'Saved',
                message: parts.join(', ') + '.',
                variant: 'success'
            }));

            this.rows = this.rows
                .filter(r => !r.markedForDeletion)
                .map(r => decorate({ ...r, dirty: false, error: null }));

            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (e) {
            this.globalError = e?.body?.message ?? 'Save failed. Please try again.';
        } finally {
            this.isBusy = false;
        }
    }
}
