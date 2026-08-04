import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import getExtractionResults from '@salesforce/apex/RFPController.getExtractionResults';
import getRFP from '@salesforce/apex/RFPController.getRFP';
import getRFPFiles from '@salesforce/apex/RFPController.getRFPFiles';
import updateResult from '@salesforce/apex/RFPController.updateResult';
import bulkAccept from '@salesforce/apex/RFPController.bulkAccept';
import finalizeRFP from '@salesforce/apex/RFPController.finalizeRFP';

const CHANNEL = '/event/RFP_Extraction_Complete__e';

export default class RfpExtractionReview extends NavigationMixin(LightningElement) {
    @api recordId;

    @track results = [];
    @track rfp = {};
    @track files = [];
    @track isBusy = false;
    @track toastMessage = null;
    @track toastVariant = 'info';
    @track activeFilter = 'all';

    _wiredResultsRef;
    _wiredRFPRef;
    _wiredFilesRef;
    _subscription;

    @wire(getRFP, { rfpId: '$recordId' })
    wiredRFP(result) {
        this._wiredRFPRef = result;
        if (result.data) {
            this.rfp = result.data;
        }
    }

    @wire(getExtractionResults, { rfpId: '$recordId' })
    wiredResults(result) {
        this._wiredResultsRef = result;
        if (result.data) {
            this.results = result.data.map(r => ({ ...r }));
        }
    }

    @wire(getRFPFiles, { rfpId: '$recordId' })
    wiredFiles(result) {
        this._wiredFilesRef = result;
        if (result.data) {
            this.files = result.data;
        }
    }

    connectedCallback() {
        this.subscribeToExtractionEvents();
        onError(error => console.error('EMP error', JSON.stringify(error)));
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription, () => {});
        }
    }

    subscribeToExtractionEvents() {
        subscribe(CHANNEL, -1, (message) => {
            const payload = message.data.payload;
            if (payload.RFP_Id__c === this.recordId) {
                if (payload.Status__c === 'Failed') {
                    this.showToast('Extraction failed: ' + payload.Error_Message__c, 'error');
                }
                refreshApex(this._wiredRFPRef);
                refreshApex(this._wiredResultsRef);
                refreshApex(this._wiredFilesRef);
            }
        }).then(sub => {
            this._subscription = sub;
        });
    }

    get isProcessing() {
        return this.rfp?.Processing_Status__c === 'Running AI';
    }

    get hasError() {
        return this.rfp?.Processing_Status__c === 'Failed';
    }

    get showReview() {
        return !this.isProcessing && !this.hasError && this.results.length > 0;
    }

    get hasResults() {
        return this.results.length > 0;
    }

    get pendingCount() {
        return this.results.filter(r => r.reviewStatus === 'Pending').length;
    }

    get requiredPendingCount() {
        return this.results.filter(r => r.isRequired && r.reviewStatus === 'Pending').length;
    }

    get hasRequiredPending() {
        return this.requiredPendingCount > 0;
    }

    get lowConfidenceCount() {
        return this.results.filter(r => this.isLowConfidence(r)).length;
    }

    isLowConfidence(r) {
        if (r.questionType === 'Reasoning') return false;
        if (r.confidenceScore == null) return false;
        const threshold = r.confidenceThreshold ?? 80;
        return r.confidenceScore < threshold;
    }

    // --- Review progress ---
    get reviewedCount() {
        return this.results.length - this.pendingCount;
    }

    get progressPercent() {
        if (!this.results.length) return 0;
        return Math.round((this.reviewedCount / this.results.length) * 100);
    }

    // --- Filtering ---
    get filteredResults() {
        switch (this.activeFilter) {
            case 'pending':
                return this.results.filter(r => r.reviewStatus === 'Pending');
            case 'required':
                return this.results.filter(r => r.isRequired && r.reviewStatus === 'Pending');
            case 'lowconf':
                return this.results.filter(r => this.isLowConfidence(r));
            default:
                return this.results;
        }
    }

    get hasFilteredResults() {
        return this.filteredResults.length > 0;
    }

    // Group the (already category-ordered) filtered results into sections.
    // Order is preserved, so the flattened group order matches filteredResults —
    // keyboard navigation in handleNavigate stays correct.
    get groupedResults() {
        const groups = [];
        const byCategory = new Map();
        for (const r of this.filteredResults) {
            const cat = r.category || 'General';
            if (!byCategory.has(cat)) {
                const g = { key: cat, category: cat, items: [] };
                byCategory.set(cat, g);
                groups.push(g);
            }
            byCategory.get(cat).items.push(r);
        }
        return groups.map(g => ({ ...g, count: g.items.length }));
    }

    get filters() {
        return [
            { key: 'all', label: 'All', count: this.results.length },
            { key: 'pending', label: 'Pending', count: this.pendingCount },
            { key: 'required', label: 'Required', count: this.requiredPendingCount },
            { key: 'lowconf', label: 'Low confidence', count: this.lowConfidenceCount }
        ].map(f => ({
            ...f,
            cssClass: f.key === this.activeFilter
                ? 'filter-chip filter-chip_active'
                : 'filter-chip'
        }));
    }

    handleFilterClick(event) {
        this.activeFilter = event.currentTarget.dataset.filter;
    }

    handleNavigate(event) {
        const { resultId, direction } = event.detail;
        const visible = this.filteredResults;
        const idx = visible.findIndex(r => r.id === resultId);
        if (idx === -1) return;
        const targetIdx = direction === 'prev' ? idx - 1 : idx + 1;
        const target = visible[targetIdx];
        if (!target) return;
        // Wait for any pending re-render before moving focus.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const el = this.template.querySelector(
                `c-rfp-result-field[data-id="${target.id}"]`
            );
            if (el) el.focusRow();
        }, 0);
    }

    get finalizeDisabled() {
        return this.isBusy || this.hasRequiredPending;
    }

    get noFiles() {
        return this.files.length === 0;
    }

    get fileSummary() {
        const count = this.files.length;
        return `${count} source file${count === 1 ? '' : 's'} included in the record-bound corpus`;
    }

    get viewFilesLabel() {
        return `View Files (${this.files.length})`;
    }

    get bulkAcceptLabel() {
        return 'Bulk Accept ≥ Threshold';
    }

    get toastClass() {
        const base = 'toast slds-notify slds-notify_toast';
        if (this.toastVariant === 'error') return base + ' slds-theme_error';
        if (this.toastVariant === 'success') return base + ' slds-theme_success';
        return base + ' slds-theme_info';
    }

    handleViewFiles() {
        const recordIds = this.files
            .map(file => file.documentId)
            .filter(Boolean);
        if (!recordIds.length) return;

        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: {
                pageName: 'filePreview'
            },
            state: {
                recordIds: recordIds.join(','),
                selectedRecordId: recordIds[0]
            }
        });
    }

    async handleResultChange(event) {
        const { resultId, status, acceptedValue } = event.detail;
        this.results = this.results.map(r =>
            r.id === resultId
                ? { ...r, reviewStatus: status, acceptedValue: acceptedValue ?? r.acceptedValue }
                : r
        );
        try {
            await updateResult({ resultId, status, acceptedValue });
        } catch (e) {
            this.showToast('Failed to save: ' + this.errorMessage(e), 'error');
            refreshApex(this._wiredResultsRef);
        }
    }

    async handleBulkAccept() {
        this.isBusy = true;
        try {
            const resultIds = this.filteredResults
                .filter(r => r.reviewStatus === 'Pending')
                .map(r => r.id);
            const count = await bulkAccept({ rfpId: this.recordId, resultIds });
            const eligibleIds = new Set(resultIds);
            this.results = this.results.map(r => {
                if (!eligibleIds.has(r.id) || r.reviewStatus !== 'Pending') return r;
                const threshold = r.confidenceThreshold ?? 80;
                if (r.confidenceScore != null && r.confidenceScore >= threshold) {
                    return { ...r, reviewStatus: 'Accepted' };
                }
                return r;
            });
            refreshApex(this._wiredResultsRef);
            this.showToast(`${count} field${count === 1 ? '' : 's'} accepted.`, 'success');
        } catch (e) {
            this.showToast('Bulk accept failed: ' + this.errorMessage(e), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    async handleFinalize() {
        this.isBusy = true;
        try {
            await finalizeRFP({ rfpId: this.recordId });
            await refreshApex(this._wiredRFPRef);
            this.dispatchEvent(new ShowToastEvent({
                title: 'RFP Extraction Saved',
                message: 'The extraction has been reviewed and saved.',
                variant: 'success'
            }));
        } catch (e) {
            this.showToast('Finalization failed: ' + this.errorMessage(e), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    showToast(message, variant = 'info') {
        this.toastMessage = message;
        this.toastVariant = variant;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.toastMessage = null; }, 5000);
    }

    errorMessage(e) {
        return e?.body?.message ?? e?.message ?? 'Unknown error';
    }
}
