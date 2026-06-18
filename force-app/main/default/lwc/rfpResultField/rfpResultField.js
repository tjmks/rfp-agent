import { LightningElement, api, track } from 'lwc';

export default class RfpResultField extends LightningElement {
    @api result;

    @track isEditing = false;
    @track showCitation = false;
    @track editValue = '';

    get displayValue() {
        return this.result.extractedValue ?? '—';
    }

    get isReasoning() {
        // promptSource is stamped at extraction time and is the authoritative source —
        // it remains correct even if the question is later retired or its type changes.
        return (this.result.promptSource ?? this.result.questionType) === 'Reasoning';
    }

    get sourceLabel() {
        return this.isReasoning ? 'Reasoning' : 'Extraction';
    }

    get sourceClass() {
        return this.isReasoning
            ? 'source-tag source-tag_reasoning'
            : 'source-tag source-tag_extraction';
    }

    get isEmpty() {
        const v = this.result.extractedValue;
        return v === null || v === undefined || String(v).trim() === '';
    }

    get isResolved() {
        return ['Accepted', 'Edited', 'Rejected'].includes(this.result.reviewStatus);
    }

    get hasCitation() {
        return !!this.result.citation;
    }

    get citationIconName() {
        return this.showCitation ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get rowClass() {
        const base = 'result-row slds-box slds-box_x-small slds-m-bottom_x-small';
        if (this.result.reviewStatus === 'Accepted' || this.result.reviewStatus === 'Edited') {
            return base + ' row_accepted';
        }
        if (this.result.reviewStatus === 'Rejected') {
            return base + ' row_rejected';
        }
        return base;
    }

    get valueClass() {
        const base = this.isReasoning
            ? 'slds-text-body_regular value_reasoning'
            : 'slds-text-body_regular';
        return this.result.reviewStatus === 'Rejected' ? base + ' value_rejected' : base;
    }

    get statusBadgeClass() {
        const s = this.result.reviewStatus;
        if (s === 'Accepted' || s === 'Edited') return 'status-badge status_accepted';
        if (s === 'Rejected') return 'status-badge status_rejected';
        return 'status-badge status_pending';
    }

    handleAccept() {
        this.dispatchResultChange('Accepted', null);
    }

    handleReject() {
        this.dispatchResultChange('Rejected', null);
    }

    handleReset() {
        this.dispatchResultChange('Pending', null);
    }

    handleEdit() {
        this.editValue = this.result.acceptedValue ?? this.result.extractedValue ?? '';
        this.isEditing = true;
    }

    handleEditChange(event) {
        this.editValue = event.target.value;
    }

    handleEditSave() {
        this.isEditing = false;
        this.dispatchResultChange('Edited', this.editValue);
    }

    handleEditCancel() {
        this.isEditing = false;
        this.editValue = '';
    }

    toggleCitation() {
        this.showCitation = !this.showCitation;
    }

    @api
    focusRow() {
        const row = this.template.querySelector('.result-row');
        if (row) {
            row.focus();
        }
    }

    handleKeyDown(event) {
        // Let the textarea own all keys while editing.
        if (this.isEditing) {
            return;
        }
        switch (event.key) {
            case 'Enter':
                if (!this.isResolved) {
                    event.preventDefault();
                    this.handleAccept();
                    this.requestNavigate('next');
                }
                break;
            case 'Escape':
                if (!this.isResolved) {
                    event.preventDefault();
                    this.handleReject();
                    this.requestNavigate('next');
                }
                break;
            case 'ArrowDown':
            case 'j':
                event.preventDefault();
                this.requestNavigate('next');
                break;
            case 'ArrowUp':
            case 'k':
                event.preventDefault();
                this.requestNavigate('prev');
                break;
            case 'e':
                if (!this.isResolved) {
                    event.preventDefault();
                    this.handleEdit();
                }
                break;
            default:
                break;
        }
    }

    requestNavigate(direction) {
        this.dispatchEvent(new CustomEvent('navigate', {
            detail: { resultId: this.result.id, direction },
            bubbles: true
        }));
    }

    dispatchResultChange(status, acceptedValue) {
        this.dispatchEvent(new CustomEvent('resultchange', {
            detail: {
                resultId: this.result.id,
                status,
                acceptedValue
            },
            bubbles: true
        }));
    }
}
