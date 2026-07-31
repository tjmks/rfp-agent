import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import AGENTFORCE_GUY from '@salesforce/resourceUrl/AgentforceGuy';
import getExtractionProfiles from '@salesforce/apex/RFPController.getExtractionProfiles';
import getRFPFiles from '@salesforce/apex/RFPController.getRFPFiles';
import initiateExtraction from '@salesforce/apex/RFPController.initiateExtraction';
import removeSessionFileLinks from '@salesforce/apex/RFPController.removeSessionFileLinks';

import ACCOUNT_ID_FIELD from '@salesforce/schema/Opportunity.AccountId';
import RFP_PROFILE_FIELD from '@salesforce/schema/RFP__c.Extraction_Profile__c';
import RFP_ACCOUNT_FIELD from '@salesforce/schema/RFP__c.Account__c';
import RFP_OPPORTUNITY_FIELD from '@salesforce/schema/RFP__c.Opportunity__c';

const SUPPORTED_EXTENSIONS = new Set(['pdf', 'png', 'jpeg', 'jpg']);

export default class RfpUploadAction extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    @track uploadedFiles = [];
    @track existingFiles = [];
    @track selectedProfileId = null;
    @track accountId = null;
    @track opportunityId = null;
    @track accountInferred = false;
    @track opportunityInferred = false;
    @track isBusy = false;
    @track isDone = false;
    @track createdRfpId = null;
    @track errorMessage = null;

    profiles = [];
    agentforceGuyUrl = AGENTFORCE_GUY;
    acceptedFileExtensions = ['.pdf', '.png', '.jpeg', '.jpg'];
    preExistingDocumentIds = [];
    baselineCaptured = false;

    connectedCallback() {
        // For an Account or Opportunity host, lightning-file-upload preserves
        // the host link. The controller later adds the same documents to the
        // newly created RFP without deleting the host link.
        if (this.objectApiName === 'Account') {
            this.accountId = this.recordId;
            this.accountInferred = true;
        } else if (this.objectApiName === 'Opportunity') {
            this.opportunityId = this.recordId;
            this.opportunityInferred = true;
        }
    }

    get recordFields() {
        if (this.objectApiName === 'Opportunity') return [ACCOUNT_ID_FIELD];
        if (this.objectApiName === 'RFP__c') {
            return [RFP_PROFILE_FIELD, RFP_ACCOUNT_FIELD, RFP_OPPORTUNITY_FIELD];
        }
        return [];
    }

    @wire(getRecord, { recordId: '$recordId', fields: '$recordFields' })
    wiredRecord({ data }) {
        if (!data) return;
        if (this.objectApiName === 'Opportunity') {
            const acct = getFieldValue(data, ACCOUNT_ID_FIELD);
            if (acct) {
                this.accountId = acct;
                this.accountInferred = true;
            }
        } else if (this.objectApiName === 'RFP__c') {
            const profileId = getFieldValue(data, RFP_PROFILE_FIELD);
            if (profileId) this.selectedProfileId = profileId;
            const acct = getFieldValue(data, RFP_ACCOUNT_FIELD);
            if (acct) {
                this.accountId = acct;
                this.accountInferred = true;
            }
            const opp = getFieldValue(data, RFP_OPPORTUNITY_FIELD);
            if (opp) {
                this.opportunityId = opp;
                this.opportunityInferred = true;
            }
        }
    }

    @wire(getExtractionProfiles)
    wiredProfiles({ data }) {
        if (data) {
            this.profiles = data;
            if (!this.selectedProfileId) {
                const defaultProfile = data.find(profile => profile.Is_Default__c);
                if (defaultProfile) this.selectedProfileId = defaultProfile.Id;
            }
        }
    }

    // Existing RFPs are record-bound corpora: every file already linked to the
    // RFP remains included even if this upload session adds nothing new.
    get existingRfpId() {
        return this.objectApiName === 'RFP__c' ? this.recordId : null;
    }

    @wire(getRFPFiles, { rfpId: '$existingRfpId' })
    wiredRfpFiles({ data, error }) {
        if (data && !this.baselineCaptured) {
            this.existingFiles = data.map(file => this.decorateFile(file));
            this.preExistingDocumentIds = data.map(file => file.documentId);
            this.baselineCaptured = true;
        } else if (error && this.objectApiName === 'RFP__c') {
            this.errorMessage = this.errorText(error);
        }
    }

    get contextRecordId() {
        return this.recordId || null;
    }

    get profileOptions() {
        return this.profiles.map(profile => ({
            label: profile.Name + (profile.Is_Default__c ? ' (Default)' : ''),
            value: profile.Id
        }));
    }

    get isExistingRfp() {
        return this.objectApiName === 'RFP__c';
    }

    get hasUploadedFiles() {
        return this.uploadedFiles.length > 0;
    }

    get hasExistingFiles() {
        return this.existingFiles.length > 0;
    }

    get hasExistingSupportedFiles() {
        return this.existingFiles.some(file => file.supported);
    }

    get unsupportedFiles() {
        return [
            ...this.existingFiles.filter(file => !file.supported),
            ...this.uploadedFiles.filter(file => !file.supported)
        ];
    }

    get hasUnsupportedFiles() {
        return this.unsupportedFiles.length > 0;
    }

    get includedFiles() {
        const existingIds = new Set(this.existingFiles.map(file => file.documentId));
        const newFiles = this.uploadedFiles.filter(file => !existingIds.has(file.documentId));
        return [...this.existingFiles, ...newFiles].filter(file => file.supported);
    }

    get includedFileCount() {
        return this.includedFiles.length;
    }

    get fileCountLabel() {
        const count = this.includedFileCount;
        return `${count} supported source file${count === 1 ? '' : 's'} will be grounded from this RFP`;
    }

    get uploadedFileCountLabel() {
        const count = this.uploadedFiles.length;
        return `${count} file${count === 1 ? '' : 's'}`;
    }

    get showConfiguration() {
        return this.hasUploadedFiles || this.hasExistingFiles;
    }

    get hasCorpusCandidate() {
        return this.includedFileCount > 0;
    }

    get accountFieldLabel() {
        return this.accountInferred ? 'Account (inherited)' : 'Account (optional)';
    }

    get opportunityFieldLabel() {
        return this.opportunityInferred ? 'Opportunity (inherited)' : 'Opportunity (optional)';
    }

    get submitDisabled() {
        return this.isBusy || !this.hasCorpusCandidate || !this.selectedProfileId;
    }

    get submitLabel() {
        return this.isBusy ? 'Starting…' : 'Start Extraction';
    }

    handleUploadFinished(event) {
        const returnedFiles = event.detail.files || [];
        const knownIds = new Set([
            ...this.existingFiles.map(file => file.documentId),
            ...this.uploadedFiles.map(file => file.documentId)
        ]);
        const newFiles = [];
        for (const file of returnedFiles) {
            if (!file.documentId || knownIds.has(file.documentId)) continue;
            const decorated = this.decorateFile({
                documentId: file.documentId,
                name: file.name,
                supported: this.isSupportedName(file.name),
                exclusionReason: this.isSupportedName(file.name) ? null : 'Unsupported file type'
            });
            newFiles.push(decorated);
            knownIds.add(file.documentId);
        }
        this.uploadedFiles = [...this.uploadedFiles, ...newFiles];
        this.errorMessage = null;
    }

    async handleRemoveFile(event) {
        const documentId = event.currentTarget.dataset.documentId;
        if (!documentId) return;

        // On an existing RFP, lightning-file-upload has already created the
        // link. Remove only a link created during this session, never a file.
        if (this.isExistingRfp && !this.preExistingDocumentIds.includes(documentId)) {
            this.isBusy = true;
            try {
                await removeSessionFileLinks({
                    rfpId: this.recordId,
                    sessionDocumentIds: [documentId],
                    preExistingDocumentIds: this.preExistingDocumentIds
                });
            } catch (e) {
                this.errorMessage = this.errorText(e);
                this.isBusy = false;
                return;
            }
            this.isBusy = false;
        }
        this.uploadedFiles = this.uploadedFiles.filter(file => file.documentId !== documentId);
    }

    handleProfileChange(event) {
        this.selectedProfileId = event.detail.value;
    }

    handleAccountChange(event) {
        this.accountId = event.detail.recordId;
        this.accountInferred = false;
    }

    handleOpportunityChange(event) {
        this.opportunityId = event.detail.recordId;
        this.opportunityInferred = false;
    }

    async handleSubmit() {
        this.isBusy = true;
        this.errorMessage = null;
        try {
            this.createdRfpId = await initiateExtraction({
                rfpId: this.isExistingRfp ? this.recordId : null,
                contentDocumentIds: this.uploadedFiles
                    .filter(file => file.supported)
                    .map(file => file.documentId),
                extractionProfileId: this.selectedProfileId,
                accountId: this.accountId,
                opportunityId: this.opportunityId
            });
            this.isDone = true;
        } catch (e) {
            this.errorMessage = this.errorText(e);
        } finally {
            this.isBusy = false;
        }
    }

    handleOpenRFP() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.createdRfpId,
                actionName: 'view'
            }
        });
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    decorateFile(file) {
        const extension = this.extensionFor(file.name || file.title || file.fileExtension);
        const supported = file.supported !== undefined
            ? file.supported
            : SUPPORTED_EXTENSIONS.has(extension);
        return {
            ...file,
            documentId: file.documentId,
            displayName: file.name || file.title || 'Unnamed file',
            extension,
            supported,
            iconName: extension === 'pdf' ? 'doctype:pdf' : 'doctype:image'
        };
    }

    extensionFor(value) {
        const text = (value || '').toLowerCase();
        const dot = text.lastIndexOf('.');
        return (dot >= 0 ? text.slice(dot + 1) : text).replace(/^\./, '');
    }

    isSupportedName(name) {
        return SUPPORTED_EXTENSIONS.has(this.extensionFor(name));
    }

    errorText(error) {
        return error?.body?.message || error?.message || 'An error occurred.';
    }
}
