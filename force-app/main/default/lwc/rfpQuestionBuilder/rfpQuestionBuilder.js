import { LightningElement, api, wire, track } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
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

// Starter categories. The live list is dynamic — users add custom categories
// inline, and any categories already saved on existing questions are merged in.
const DEFAULT_CATEGORIES = ['General', 'Commercial', 'Technical', 'Compliance'];
const NEW_CATEGORY_SENTINEL = '__new_category__';

const HELP = {
    questionLabel: 'A short, human-readable name for this field. Appears as the column header in extraction results. Keep it under ~30 characters. Example: "Submission Deadline".',
    questionPrompt: 'The natural-language question the AI will answer. Be specific and include format hints. Example: "What is the deadline for submitting the proposal? Return as YYYY-MM-DD."',
    questionType: 'Routes the question to a different AI prompt.\n\nExtraction — best when the answer appears directly in the document (deadlines, prices, named entities, contacts). Returns a confidence score per answer and contributes to the overall RFP confidence rollup.\n\nReasoning — best when the answer requires synthesis across multiple sections (scope summaries, fit assessments, derived implications, comparisons). Runs on a separate template; confidence is fuzzy and excluded from the rollup.',
    outputType: 'How the answer should be formatted. Text/Long Text for free-form. Number/Currency/Date for typed values (validated). Boolean for yes/no. List for multi-value answers.',
    category: 'Groups this question in the review screen (Commercial / Technical / Compliance / General). Purely organizational — it does not change how the AI answers.',
    extractionHint: 'Optional context that steers the AI to the right section, e.g. "Look in the timeline or schedule section". Useful when the prompt alone is ambiguous.',
    required: 'When checked, RFP processing flags missing answers for review. Optional questions return null silently if no answer is found.',
    confidenceThreshold: 'Minimum confidence score (0–100) the AI must report for an extracted answer to be considered high-confidence. Answers below this value appear in the Low Confidence filter for human review. Defaults to 80. Not applied to Reasoning questions.'
};

const CARD_BASE = 'q-card slds-box slds-box_x-small slds-theme_default';

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
        creatingCategory: false,
        newCategoryValue: '',
        isRequired: false,
        extractionHint: '',
        showHint: false,
        confidenceThreshold: 80,
        error: null,
        dirty: false,
        markedForDeletion: false,
        ...overrides
    };
    return decorate(row);
}

function decorate(row) {
    const mods = [];
    if (row.markedForDeletion) mods.push('q-card_pending-delete');
    else {
        if (row.error) mods.push('q-card_error');
        if (row.sfId && row.dirty) mods.push('q-card_dirty');
    }
    const cardClass = `${CARD_BASE}${mods.length ? ' ' + mods.join(' ') : ''}`;
    const hintIcon = row.showHint ? 'utility:chevrondown' : 'utility:chevronright';
    const hintIsSet = !!row.extractionHint?.trim();
    let hintLabel;
    if (row.showHint) hintLabel = 'Extraction hint';
    else if (hintIsSet) hintLabel = 'Extraction hint set';
    else hintLabel = 'Extraction hint (optional)';
    const hintDisclosureClass = `slds-button slds-button_reset hint-disclosure${
        !row.showHint && hintIsSet ? ' hint-disclosure_set' : ''
    }`;
    const isReasoning = row.questionType === 'Reasoning';
    return { ...row, cardClass, hintIcon, hintLabel, hintDisclosureClass, isReasoning };
}

export default class RfpQuestionBuilder extends LightningElement {
    @api recordId;

    @track rows = [];
    @track isBusy = false;
    @track globalError = null;
    @track overviewMode = true;
    @track categoryList = [...DEFAULT_CATEGORIES];

    typeOptions = TYPE_OPTIONS;
    questionTypeOptions = QUESTION_TYPE_OPTIONS;

    helpQuestionLabel = HELP.questionLabel;
    helpQuestionPrompt = HELP.questionPrompt;
    helpQuestionType = HELP.questionType;
    helpOutputType = HELP.outputType;
    helpCategory = HELP.category;
    helpExtractionHint = HELP.extractionHint;
    helpRequired = HELP.required;
    helpConfidenceThreshold = HELP.confidenceThreshold;

    _originalOrder = new Map(); // sfId -> original index
    _dragSourceId = null;

    @wire(getExistingQuestions, { profileId: '$recordId' })
    wiredQuestions({ data }) {
        if (data) {
            this._originalOrder = new Map();
            // Merge any saved categories into the live option list.
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
                    extractionHint: q.Extraction_Hint__c || '',
                    showHint: false,
                    confidenceThreshold: q.Confidence_Threshold__c ?? 80,
                    dirty: false
                });
            });
        }
    }

    // ── Derived state ──────────────────────────────────────────────────────

    get visibleRows() {
        let n = 0;
        return this.rows.map(r => {
            const active = !r.markedForDeletion;
            if (active) n++;
            return {
                ...r,
                position: active ? n : null,
                isExisting: !!r.sfId,
                showActiveBody: active
            };
        });
    }

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

    get categoryOptions() {
        const opts = this.categoryList.map(c => ({ label: c, value: c }));
        opts.push({ label: '+ New category…', value: NEW_CATEGORY_SENTINEL });
        return opts;
    }

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

    // ── Overview mode ──────────────────────────────────────────────────────

    toggleOverviewMode() {
        this.overviewMode = !this.overviewMode;
    }

    get editMode() {
        return !this.overviewMode;
    }

    get modeToggleLabel() {
        return this.overviewMode ? 'Switch to Edit' : 'Switch to Overview';
    }

    get overviewGroups() {
        const live = this.rows.filter(r => !r.markedForDeletion);
        const groups = [];
        const byCat = new Map();
        for (const r of live) {
            const cat = (r.category && r.category.trim()) || 'General';
            if (!byCat.has(cat)) {
                const g = { key: cat, category: cat, items: [] };
                byCat.set(cat, g);
                groups.push(g);
            }
            byCat.get(cat).items.push({
                id: r.id,
                questionLabel: r.questionLabel || '(untitled)',
                questionText: r.questionText || '—'
            });
        }
        // General first, then alphabetical.
        groups.sort((a, b) => {
            if (a.category === 'General') return -1;
            if (b.category === 'General') return 1;
            return a.category.toLowerCase().localeCompare(b.category.toLowerCase());
        });
        return groups;
    }

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

    handleGroundingSaved() {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Saved',
            message: 'Grounding context updated.',
            variant: 'success'
        }));
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

    addQuestion() {
        const newRow = makeRow();
        this.rows = [...this.rows, newRow];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const inputs = this.template.querySelectorAll(
                `lightning-input[data-id="${newRow.id}"][data-field="questionLabel"]`
            );
            if (inputs.length) inputs[0].focus();
        }, 50);
    }

    handleFieldChange(event) {
        const { id, field } = event.currentTarget.dataset;
        this._patchRow(id, { [field]: event.target.value });
    }

    handleRequiredChange(event) {
        const { id } = event.currentTarget.dataset;
        this._patchRow(id, { isRequired: event.target.checked });
    }

    handleCategoryChange(event) {
        const { id } = event.currentTarget.dataset;
        const value = event.detail.value;
        if (value === NEW_CATEGORY_SENTINEL) {
            // Enter inline-create mode without changing the saved category yet.
            this.rows = this.rows.map(r =>
                r.id === id ? decorate({ ...r, creatingCategory: true, newCategoryValue: '' }) : r
            );
            return;
        }
        this._patchRow(id, { category: value });
    }

    handleNewCategoryInput(event) {
        const { id } = event.currentTarget.dataset;
        const draft = event.target.value;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, newCategoryValue: draft }) : r
        );
    }

    confirmNewCategory(event) {
        const { id } = event.currentTarget.dataset;
        const row = this.rows.find(r => r.id === id);
        const name = (row?.newCategoryValue || '').trim();
        if (!name) {
            this.cancelNewCategory(event);
            return;
        }
        // Reuse an existing category if it matches case-insensitively.
        const existing = this.categoryList.find(c => c.toLowerCase() === name.toLowerCase());
        const finalName = existing || name;
        if (!existing) {
            this.mergeCategories([finalName]);
        }
        this.rows = this.rows.map(r =>
            r.id === id
                ? decorate({
                      ...r,
                      category: finalName,
                      creatingCategory: false,
                      newCategoryValue: '',
                      dirty: r.sfId ? true : r.dirty,
                      error: null
                  })
                : r
        );
        this.globalError = null;
    }

    cancelNewCategory(event) {
        const { id } = event.currentTarget.dataset;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, creatingCategory: false, newCategoryValue: '' }) : r
        );
    }

    toggleHint(event) {
        const { id } = event.currentTarget.dataset;
        this.rows = this.rows.map(r =>
            r.id === id ? decorate({ ...r, showHint: !r.showHint }) : r
        );
    }

    removeHint(event) {
        const { id } = event.currentTarget.dataset;
        this._patchRow(id, { extractionHint: '', showHint: false });
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
            extractionHint: src.extractionHint,
            showHint: src.showHint,
            confidenceThreshold: src.confidenceThreshold
        });
        const next = [...this.rows];
        next.splice(idx + 1, 0, clone);
        this.rows = next;
    }

    deleteRow(event) {
        const { id } = event.currentTarget.dataset;
        const target = this.rows.find(r => r.id === id);
        if (!target) return;
        if (!target.sfId) {
            this.rows = this.rows.filter(r => r.id !== id);
            return;
        }
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
        // Required for Firefox to fire drag events
        try { event.dataTransfer.setData('text/plain', id); } catch (e) { /* ignore */ }
        event.currentTarget.classList.add('q-card_dragging');
    }

    onDragEnd(event) {
        event.currentTarget.classList.remove('q-card_dragging');
        this.template.querySelectorAll('.q-card_drop-target').forEach(el =>
            el.classList.remove('q-card_drop-target')
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
        event.currentTarget.classList.add('q-card_drop-target');
    }

    onDragLeave(event) {
        event.currentTarget.classList.remove('q-card_drop-target');
    }

    onDrop(event) {
        event.preventDefault();
        const targetId = event.currentTarget.dataset.id;
        const sourceId = this._dragSourceId;
        event.currentTarget.classList.remove('q-card_drop-target');
        if (!sourceId || sourceId === targetId) return;

        const src = this.rows.findIndex(r => r.id === sourceId);
        const tgt = this.rows.findIndex(r => r.id === targetId);
        if (src < 0 || tgt < 0) return;

        const next = [...this.rows];
        const [moved] = next.splice(src, 1);
        next.splice(tgt, 0, moved);
        this.rows = next;
    }

    // ── Save ───────────────────────────────────────────────────────────────

    async handleSave() {
        // Validate new (non-deleted) rows: label and prompt must agree
        let hasRowErrors = false;
        const validated = this.rows.map(r => {
            if (r.sfId || r.markedForDeletion) return r;
            const hasLabel = !!r.questionLabel?.trim();
            const hasText = !!r.questionText?.trim();
            if (hasLabel && !hasText) {
                hasRowErrors = true;
                return decorate({ ...r, error: 'Question prompt is required.' });
            }
            if (!hasLabel && hasText) {
                hasRowErrors = true;
                return decorate({ ...r, error: 'Label is required.' });
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

        // Compute final sort order for non-deleted rows: index*10 in current order
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
                    extractionHint: r.extractionHint?.trim() || null,
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
                    extractionHint: r.extractionHint?.trim() || null,
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

            // Drop deleted rows; mark survivors clean. Wire will refresh from server with new IDs/order.
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
