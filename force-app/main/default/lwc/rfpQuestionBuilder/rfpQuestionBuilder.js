import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getBuilderState from '@salesforce/apex/RFPQuestionBuilderController.getBuilderState';
import saveBuilder from '@salesforce/apex/RFPQuestionBuilderController.saveBuilder';

const OUTPUT_TYPES = ['Text', 'Long Text', 'Number', 'Date', 'Currency', 'Boolean', 'List'];
const QUESTION_TYPE_OPTIONS = [
    { label: 'Extraction', value: 'Extraction' },
    { label: 'Reasoning', value: 'Reasoning' }
];
const DEFAULT_CATEGORY = 'General';
const NEW_CATEGORY = '__new__';
const DEFAULT_THRESHOLD = 80;
const MAX_LABEL_LENGTH = 80;

// Fields compared against the saved snapshot to decide whether a row changed.
const EDITABLE_FIELDS = [
    'label', 'questionText', 'hint', 'questionType', 'outputType',
    'category', 'isRequired', 'confidenceThreshold'
];

const HELP = {
    label: 'Short name for the answer. Becomes the field label on the review screen, so it must be unique in this profile.',
    questionText: 'What the AI should answer. Be specific and include format hints, e.g. "What is the submission deadline? Return YYYY-MM-DD."',
    hint: 'Optional. Extra guidance appended to the question, such as where to look or what to do when the answer is missing.',
    questionType: 'Decides which AI prompt answers this question. Extraction finds a fact that is written in the RFP, such as a deadline, budget or contact, and scores how confident it is. Reasoning asks the AI to analyse the whole RFP against your company context, such as risks, fit or win themes; these answers have no confidence score.',
    outputType: 'The shape of the answer. Typed answers (Number, Currency, Date, Boolean) are validated and can be written into matching RFP fields.',
    threshold: 'Answers scored below this confidence show up in the Low Confidence filter for review.',
    required: 'The RFP can\'t be approved until this answer is reviewed.',
    grounding: 'Background about your company: industry, products, strengths, weaknesses. Reasoning questions use it to judge fit; Extraction questions see it as background only.'
};

const TYPE_CAPTIONS = {
    Extraction: 'Finds a fact stated in the RFP. Answers get a confidence score and can be bulk-accepted.',
    Reasoning: 'Analyses the RFP using your company context. Answers have no confidence score.'
};

let keySeq = 0;
const nextKey = () => `q${++keySeq}`;

const trimmed = value => (value ?? '').toString().trim();

function toRow(q) {
    return {
        key: nextKey(),
        id: q.id || null,
        label: q.label || '',
        questionText: q.questionText || '',
        hint: q.extractionHint || '',
        questionType: q.questionType || 'Extraction',
        outputType: q.outputType || 'Text',
        category: q.category || '',
        isRequired: !!q.isRequired,
        confidenceThreshold: q.confidenceThreshold ?? DEFAULT_THRESHOLD,
        removed: false,
        error: null
    };
}

function isBlankRow(r) {
    return !trimmed(r.label) && !trimmed(r.questionText);
}

// Extraction sorts questions by category (blank last), then sort order. Keep
// the rows array in that order so what the user sees is what the AI gets.
function categoryKey(category) {
    return trimmed(category).toLowerCase();
}

function compareCategories(a, b) {
    const ka = categoryKey(a);
    const kb = categoryKey(b);
    if (ka === kb) return 0;
    if (!ka) return 1;
    if (!kb) return -1;
    return ka.localeCompare(kb);
}

function sortRows(rows) {
    return rows
        .map((row, index) => ({ row, index }))
        .sort((a, b) => compareCategories(a.row.category, b.row.category) || a.index - b.index)
        .map(entry => entry.row);
}

function layoutOf(rows) {
    return rows.filter(r => r.id && !r.removed).map(r => `${r.id}@${categoryKey(r.category)}`);
}

function reduceError(error) {
    return error?.body?.message || error?.message || 'Something went wrong.';
}

export default class RfpQuestionBuilder extends LightningElement {
    @api recordId;

    rows = [];
    grounding = '';
    starterQuestions = [];
    canEdit = false;
    isLoading = true;
    isSaving = false;
    loadError = null;
    expandedKey = null;
    newCategoryKey = null;
    emptyCategories = [];
    isAddingCategory = false;
    renamingCategory = null;
    dragKey = null;
    dropKey = null;

    help = HELP;
    questionTypeOptions = QUESTION_TYPE_OPTIONS;
    outputTypeOptions = OUTPUT_TYPES.map(t => ({ label: t, value: t }));

    _lastState = null;
    _snapshots = new Map();
    _savedSortOrders = new Map();
    _savedLayout = [];
    _savedGrounding = '';
    _focusSelector = null;
    _cancelNewCategory = false;

    _onBeforeUnload = event => {
        if (this.changeCount > 0) {
            event.preventDefault();
            event.returnValue = '';
        }
    };

    connectedCallback() {
        window.addEventListener('beforeunload', this._onBeforeUnload);
        this.load();
    }

    disconnectedCallback() {
        window.removeEventListener('beforeunload', this._onBeforeUnload);
    }

    renderedCallback() {
        if (!this._focusSelector) return;
        const input = this.template.querySelector(this._focusSelector);
        if (input) {
            input.focus();
            this._focusSelector = null;
        }
    }

    async load() {
        this.isLoading = true;
        this.loadError = null;
        try {
            this.applyState(await getBuilderState({ profileId: this.recordId }));
        } catch (error) {
            this.loadError = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    applyState(state) {
        this._lastState = state;
        this.canEdit = !!state.canEdit;
        this.starterQuestions = state.starterQuestions || [];
        this.grounding = state.groundingContext || '';
        this._savedGrounding = this.grounding;

        const questions = state.questions || [];
        const rows = questions.map(toRow);
        this._snapshots = new Map(rows.map(r => [r.id, this.snapshot(r)]));
        this._savedSortOrders = new Map(questions.map(q => [q.id, q.sortOrder]));
        this._savedLayout = layoutOf(rows);
        this.rows = rows;
        this.expandedKey = null;
        this.newCategoryKey = null;
        this.emptyCategories = [];
        this.isAddingCategory = false;
        this.renamingCategory = null;
    }

    snapshot(row) {
        const snap = {};
        EDITABLE_FIELDS.forEach(f => { snap[f] = this.normalize(f, row[f]); });
        return snap;
    }

    normalize(field, value) {
        if (field === 'isRequired') return !!value;
        if (field === 'confidenceThreshold') return value === '' || value == null ? null : Number(value);
        return trimmed(value);
    }

    // ── Change tracking ─────────────────────────────────────────────────────

    isEdited(row) {
        const snap = row.id && this._snapshots.get(row.id);
        if (!snap) return false;
        return EDITABLE_FIELDS.some(f => {
            // Reasoning ignores the threshold, so changing it there isn't a change.
            if (f === 'confidenceThreshold' && row.questionType === 'Reasoning') return false;
            return this.normalize(f, row[f]) !== snap[f];
        });
    }

    isNew(row) {
        return !row.id && !row.removed && !isBlankRow(row);
    }

    get layoutChanged() {
        const current = layoutOf(this.rows);
        const currentIds = new Set(this.rows.filter(r => r.id && !r.removed).map(r => `${r.id}@${categoryKey(r.category)}`));
        const saved = this._savedLayout.filter(entry => currentIds.has(entry));
        return current.length !== saved.length || current.some((entry, i) => entry !== saved[i]);
    }

    get groundingChanged() {
        return trimmed(this.grounding) !== trimmed(this._savedGrounding);
    }

    get changeCount() {
        let count = 0;
        for (const r of this.rows) {
            if (r.removed ? !!r.id : this.isNew(r) || this.isEdited(r)) count++;
        }
        // A pure reorder counts once, however many rows moved.
        const editedCategory = this.rows.some(r => r.id && !r.removed &&
            categoryKey(r.category) !== categoryKey(this._snapshots.get(r.id)?.category));
        if (this.layoutChanged && !editedCategory) count++;
        if (this.groundingChanged) count++;
        return count;
    }

    get hasChanges() {
        return this.canEdit && this.changeCount > 0;
    }

    get changeLabel() {
        const n = this.changeCount;
        return `${n} unsaved change${n === 1 ? '' : 's'}`;
    }

    // ── View model ──────────────────────────────────────────────────────────

    get isReadOnly() {
        return !this.canEdit || this.isSaving;
    }

    get liveRows() {
        return this.rows.filter(r => !r.removed);
    }

    get hasQuestions() {
        return this.rows.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.loadError && !this.hasQuestions;
    }

    get hasStarterQuestions() {
        return this.canEdit && this.starterQuestions.length > 0;
    }

    get starterLabel() {
        return `Use the ${this.starterQuestions.length} starter questions`;
    }

    get summary() {
        const live = this.liveRows;
        if (!live.length) return '';
        const reasoning = live.filter(r => r.questionType === 'Reasoning').length;
        const extraction = live.length - reasoning;
        return `${live.length} question${live.length === 1 ? '' : 's'} · ${extraction} extraction · ${reasoning} reasoning`;
    }

    // Every category name in play: used by questions, or created empty here.
    get categoryNames() {
        const seen = new Map();
        [...this.liveRows.map(r => r.category), ...this.emptyCategories].forEach(c => {
            const name = trimmed(c);
            if (name && !seen.has(categoryKey(name))) seen.set(categoryKey(name), name);
        });
        return [...seen.values()].sort(compareCategories);
    }

    get categoryOptions() {
        const names = this.categoryNames;
        if (!names.some(n => categoryKey(n) === categoryKey(DEFAULT_CATEGORY))) names.push(DEFAULT_CATEGORY);
        names.sort(compareCategories);
        return [
            ...names.map(name => ({ label: name, value: name })),
            { label: '+ New category…', value: NEW_CATEGORY }
        ];
    }

    get groups() {
        const categoryOptions = this.categoryOptions;
        const groups = [];
        let current = null;
        this.rows.forEach(row => {
            const key = categoryKey(row.category) || '__none__';
            if (!current || current.key !== key) {
                current = {
                    key,
                    category: trimmed(row.category),
                    name: trimmed(row.category) || 'Uncategorized',
                    rows: []
                };
                groups.push(current);
            }
            current.rows.push(row);
        });
        // Categories created here but not used by any question yet.
        this.emptyCategories.forEach(name => {
            if (!groups.some(g => g.key === categoryKey(name))) {
                groups.push({ key: categoryKey(name), category: name, name, rows: [] });
            }
        });
        groups.sort((a, b) => compareCategories(a.category, b.category));

        return groups.map(group => {
            const live = group.rows.filter(r => !r.removed);
            return {
                ...group,
                count: live.length,
                isEmpty: live.length === 0,
                isNamed: !!group.category,
                isRenaming: this.renamingCategory === group.key,
                dropClass: `group-drop${this.dropKey === `group:${group.key}` ? ' group-drop_active' : ''}`,
                dropKey: `group:${group.key}`,
                rows: group.rows.map(row => this.viewRow(row, live, categoryOptions))
            };
        });
    }

    viewRow(row, liveInGroup, categoryOptions) {
        const isExpanded = this.expandedKey === row.key;
        const isReasoning = row.questionType === 'Reasoning';
        const position = liveInGroup.indexOf(row);
        const isDirty = this.isNew(row) || this.isEdited(row);

        const classes = ['q-row', isReasoning ? 'q-row_reasoning' : 'q-row_extraction'];
        if (isExpanded) classes.push('q-row_expanded');
        if (row.error) classes.push('q-row_error');
        if (this.dragKey === row.key) classes.push('q-row_dragging');
        if (this.dropKey === row.key) classes.push('q-row_drop-target');

        return {
            ...row,
            isExpanded,
            isReasoning,
            isDirty,
            rowClass: classes.join(' '),
            draggable: this.canEdit && !isExpanded && !row.removed ? 'true' : 'false',
            displayLabel: trimmed(row.label) || 'Untitled question',
            labelClass: trimmed(row.label) ? 'q-label' : 'q-label q-label_empty',
            preview: trimmed(row.questionText) || 'No question text yet',
            typeBadgeClass: `q-badge ${isReasoning ? 'q-badge_reasoning' : 'q-badge_extraction'}`,
            questionTypeCaption: isReasoning ? TYPE_CAPTIONS.Reasoning : TYPE_CAPTIONS.Extraction,
            thresholdValue: row.confidenceThreshold ?? DEFAULT_THRESHOLD,
            categoryOptions,
            isNewCategory: this.newCategoryKey === row.key,
            chevron: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
            cannotMoveUp: position <= 0,
            cannotMoveDown: position < 0 || position === liveInGroup.length - 1,
            ariaExpanded: isExpanded ? 'true' : 'false'
        };
    }

    // ── Row editing ─────────────────────────────────────────────────────────

    patchRow(key, patch) {
        this.rows = this.rows.map(r => (r.key === key ? { ...r, ...patch, error: null } : r));
    }

    focusField(key, field) {
        this._focusSelector = `[data-key="${key}"][data-field="${field}"]`;
    }

    rowFor(key) {
        return this.rows.find(r => r.key === key);
    }

    handleToggle(event) {
        const { key } = event.currentTarget.dataset;
        this.expandedKey = this.expandedKey === key ? null : key;
    }

    handleHeaderKeydown(event) {
        if (event.target !== event.currentTarget) return;
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleToggle(event);
        }
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleDone() {
        this.expandedKey = null;
    }

    handleFieldChange(event) {
        const { key, field } = event.target.dataset;
        const value = event.detail?.value ?? event.target.value;
        this.patchRow(key, { [field]: value });
    }

    handleRequiredChange(event) {
        this.patchRow(event.target.dataset.key, { isRequired: event.target.checked });
    }

    handleThresholdChange(event) {
        this.patchRow(event.target.dataset.key, { confidenceThreshold: Number(event.detail.value) });
    }

    handleQuestionTypeChange(event) {
        const { key } = event.target.dataset;
        const questionType = event.detail.value;
        const row = this.rowFor(key);
        const patch = { questionType };
        // Reasoning questions are stored with a 0 threshold; give Extraction a usable default back.
        if (questionType === 'Extraction' && !Number(row.confidenceThreshold)) {
            patch.confidenceThreshold = DEFAULT_THRESHOLD;
        }
        this.patchRow(key, patch);
    }

    handleCategoryChange(event) {
        const { key } = event.target.dataset;
        const value = event.detail.value;
        if (value === NEW_CATEGORY) {
            this.newCategoryKey = key;
            this.focusField(key, 'newCategory');
            return;
        }
        this.setCategory(key, value);
    }

    handleNewCategoryCommit(event) {
        const { key } = event.target.dataset;
        const name = trimmed(event.target.value);
        const cancelled = this._cancelNewCategory;
        this._cancelNewCategory = false;
        this.newCategoryKey = null;
        if (!name || cancelled) return;
        const existing = this.categoryOptions.find(o => o.value !== NEW_CATEGORY && categoryKey(o.value) === categoryKey(name));
        this.setCategory(key, existing ? existing.value : name);
    }

    handleNewCategoryKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this._cancelNewCategory = true;
            this.newCategoryKey = null;
        } else if (event.key === 'Enter') {
            this.handleNewCategoryCommit(event);
        }
    }

    setCategory(key, category) {
        const row = this.rowFor(key);
        if (categoryKey(row.category) === categoryKey(category)) return;
        // Moving to the end of the array lands the row last in its new category.
        const others = this.rows.filter(r => r.key !== key);
        this.rows = sortRows([...others, { ...row, category, error: null }]);
    }

    // ── Category management ─────────────────────────────────────────────────

    handleNewCategoryClick() {
        this.isAddingCategory = true;
        this._focusSelector = '[data-field="addCategory"]';
    }

    handleAddCategoryKeydown(event) {
        if (event.key === 'Escape') {
            this._cancelNewCategory = true;
            this.isAddingCategory = false;
        } else if (event.key === 'Enter') {
            this.handleAddCategoryCommit(event);
        }
    }

    handleAddCategoryCommit(event) {
        const name = trimmed(event.target.value);
        const cancelled = this._cancelNewCategory;
        this._cancelNewCategory = false;
        this.isAddingCategory = false;
        if (!name || cancelled) return;
        if (!this.categoryNames.some(n => categoryKey(n) === categoryKey(name))) {
            this.emptyCategories = [...this.emptyCategories, name];
        }
    }

    handleCategoryMenuSelect(event) {
        const { category } = event.target.dataset;
        if (event.detail.value === 'rename') {
            this.renamingCategory = categoryKey(category);
            this._focusSelector = '[data-field="renameCategory"]';
        } else if (event.detail.value === 'remove') {
            this.removeCategory(category);
        }
    }

    handleRenameKeydown(event) {
        if (event.key === 'Escape') {
            this._cancelNewCategory = true;
            this.renamingCategory = null;
        } else if (event.key === 'Enter') {
            this.handleRenameCommit(event);
        }
    }

    handleRenameCommit(event) {
        const from = event.target.dataset.category;
        const cancelled = this._cancelNewCategory;
        this._cancelNewCategory = false;
        this.renamingCategory = null;
        // Renaming onto an existing category merges the two.
        const typed = trimmed(event.target.value);
        if (cancelled || !typed || typed === from) return;
        const to = this.categoryNames.find(n => categoryKey(n) === categoryKey(typed) && categoryKey(n) !== categoryKey(from)) || typed;
        this.emptyCategories = this.emptyCategories.map(c => (categoryKey(c) === categoryKey(from) ? to : c));
        this.rows = sortRows(this.rows.map(r =>
            categoryKey(r.category) === categoryKey(from) ? { ...r, category: to, error: null } : r));
    }

    async removeCategory(category) {
        const key = categoryKey(category);
        const count = this.liveRows.filter(r => categoryKey(r.category) === key).length;
        if (count > 0) {
            const confirmed = await LightningConfirm.open({
                message: `Remove the "${category}" category? Its ${count} question${count === 1 ? '' : 's'} stay, but move to Uncategorized.`,
                label: 'Remove category',
                theme: 'warning'
            });
            if (!confirmed) return;
        }
        this.emptyCategories = this.emptyCategories.filter(c => categoryKey(c) !== key);
        this.rows = sortRows(this.rows.map(r =>
            categoryKey(r.category) === key ? { ...r, category: '', error: null } : r));
    }

    handleMenuSelect(event) {
        const { key } = event.target.dataset;
        const action = event.detail.value;
        if (action === 'up' || action === 'down') this.move(key, action === 'up' ? -1 : 1);
        else if (action === 'duplicate') this.duplicate(key);
        else if (action === 'remove') this.remove(key);
    }

    move(key, direction) {
        const row = this.rowFor(key);
        const sameGroup = this.rows.filter(r => !r.removed && categoryKey(r.category) === categoryKey(row.category));
        const neighbour = sameGroup[sameGroup.indexOf(row) + direction];
        if (!neighbour) return;
        const next = [...this.rows];
        const a = next.indexOf(row);
        const b = next.indexOf(neighbour);
        [next[a], next[b]] = [next[b], next[a]];
        this.rows = next;
    }

    duplicate(key) {
        const source = this.rowFor(key);
        const copy = { ...source, key: nextKey(), id: null, removed: false, error: null,
            label: source.label ? `${trimmed(source.label)} (copy)` : '' };
        const next = [...this.rows];
        next.splice(next.indexOf(source) + 1, 0, copy);
        this.rows = next;
        this.expandedKey = copy.key;
        this.focusField(copy.key, 'label');
    }

    remove(key) {
        const row = this.rowFor(key);
        if (this.expandedKey === key) this.expandedKey = null;
        this.rows = row.id
            ? this.rows.map(r => (r.key === key ? { ...r, removed: true, error: null } : r))
            : this.rows.filter(r => r.key !== key);
    }

    handleUndoRemove(event) {
        this.patchRow(event.currentTarget.dataset.key, { removed: false });
    }

    handleAddQuestion(event) {
        const category = event.currentTarget.dataset.category ?? DEFAULT_CATEGORY;
        const row = toRow({ category });
        this.rows = sortRows([...this.rows, row]);
        this.expandedKey = row.key;
        this.focusField(row.key, 'label');
    }

    handleUseStarter() {
        this.rows = sortRows(this.starterQuestions.map(toRow));
        this.expandedKey = null;
    }

    handleGroundingChange(event) {
        this.grounding = event.target.value;
    }

    // ── Drag and drop ───────────────────────────────────────────────────────

    handleDragStart(event) {
        this.dragKey = event.currentTarget.dataset.key;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this.dragKey);
    }

    handleDragEnd() {
        this.dragKey = null;
        this.dropKey = null;
    }

    handleDragOver(event) {
        if (!this.dragKey) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        const { dropKey } = event.currentTarget.dataset;
        if (dropKey !== this.dragKey && this.dropKey !== dropKey) this.dropKey = dropKey;
    }

    handleDrop(event) {
        event.preventDefault();
        const { dropKey } = event.currentTarget.dataset;
        const source = this.rowFor(this.dragKey);
        this.dragKey = null;
        this.dropKey = null;
        if (!source || dropKey === source.key) return;

        const others = this.rows.filter(r => r.key !== source.key);
        if (dropKey.startsWith('group:')) {
            // Dropped on a category's footer: last in that category.
            const category = event.currentTarget.dataset.category;
            this.rows = sortRows([...others, { ...source, category }]);
            return;
        }
        const target = others.find(r => r.key === dropKey);
        others.splice(others.indexOf(target), 0, { ...source, category: target.category });
        this.rows = sortRows(others);
    }

    // ── Save / discard ──────────────────────────────────────────────────────

    validate(rows) {
        const errors = new Map();
        const labels = new Set();
        rows.forEach(r => {
            let error = null;
            const label = trimmed(r.label);
            const threshold = Number(r.confidenceThreshold);
            if (!label) error = 'Add a label.';
            else if (label.length > MAX_LABEL_LENGTH) error = `Keep the label to ${MAX_LABEL_LENGTH} characters or fewer.`;
            else if (labels.has(label.toLowerCase())) error = 'Another question already uses this label.';
            else if (!trimmed(r.questionText)) error = 'Add the question the AI should answer.';
            else if (r.questionType === 'Extraction' && (Number.isNaN(threshold) || threshold < 0 || threshold > 100)) {
                error = 'Set a confidence threshold between 0 and 100.';
            }
            if (label) labels.add(label.toLowerCase());
            if (error) errors.set(r.key, error);
        });
        return errors;
    }

    showRowErrors(errors) {
        this.rows = this.rows.map(r => ({ ...r, error: errors.get(r.key) || null }));
        const first = this.rows.find(r => r.error);
        if (first) this.expandedKey = first.key;
        this.toast('Fix the highlighted questions', `${errors.size} question${errors.size === 1 ? ' needs' : 's need'} attention before saving.`, 'error');
    }

    async handleSave() {
        // Questions added but never filled in are just dropped.
        this.rows = this.rows.filter(r => r.id || !isBlankRow(r));
        const live = this.liveRows;
        const errors = this.validate(live);
        if (errors.size) {
            this.showRowErrors(errors);
            return;
        }

        const renumber = this.layoutChanged || live.some(r => !r.id);
        const questions = [];
        live.forEach((r, index) => {
            const saved = r.id ? this._savedSortOrders.get(r.id) : null;
            const sortOrder = renumber ? (index + 1) * 10 : saved ?? (index + 1) * 10;
            if (!r.id || this.isEdited(r) || sortOrder !== saved) {
                questions.push({
                    clientKey: r.key,
                    id: r.id,
                    label: trimmed(r.label),
                    questionText: trimmed(r.questionText),
                    extractionHint: trimmed(r.hint),
                    questionType: r.questionType,
                    outputType: r.outputType,
                    category: trimmed(r.category),
                    isRequired: r.isRequired,
                    confidenceThreshold: Number(r.confidenceThreshold),
                    sortOrder
                });
            }
        });
        const retireIds = this.rows.filter(r => r.removed && r.id).map(r => r.id);

        this.isSaving = true;
        try {
            const result = await saveBuilder({
                profileId: this.recordId,
                groundingContext: this.grounding,
                groundingChanged: this.groundingChanged,
                questions,
                retireIds
            });
            if (!result.success) {
                this.showRowErrors(new Map(Object.entries(result.rowErrors || {})));
                return;
            }
            this.applyState(result.state);
            this.toast('Questions saved', null, 'success');
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.toast('Couldn\'t save', reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDiscard() {
        const confirmed = await LightningConfirm.open({
            message: `Discard ${this.changeLabel.replace('unsaved ', '')}? This can't be undone.`,
            label: 'Discard changes',
            theme: 'warning'
        });
        if (confirmed) this.applyState(this._lastState);
    }

    handleRetry() {
        this.load();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
