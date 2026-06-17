import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import AGENTFORCE_GUY from '@salesforce/resourceUrl/AgentforceGuy';
import getExtractionProfiles from '@salesforce/apex/RFPController.getExtractionProfiles';
import initiateExtraction from '@salesforce/apex/RFPController.initiateExtraction';

import ACCOUNT_ID_FIELD from '@salesforce/schema/Opportunity.AccountId';
import RFP_PROFILE_FIELD from '@salesforce/schema/RFP__c.Extraction_Profile__c';
import RFP_ACCOUNT_FIELD from '@salesforce/schema/RFP__c.Account__c';
import RFP_OPPORTUNITY_FIELD from '@salesforce/schema/RFP__c.Opportunity__c';

export default class RfpUploadAction extends NavigationMixin(LightningElement) {
    // When launched as a quick action from a record page, the platform
    // passes the host record's Id here.
    @api recordId;
    @api objectApiName;

    @track uploadedFileId = null;
    @track uploadedFileName = '';
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

    connectedCallback() {
        // Inference for Account doesn't need the wire — set immediately so the
        // RFP gets linked even if the user submits before any record loads.
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
        if (this.objectApiName === 'RFP__c') return [RFP_PROFILE_FIELD, RFP_ACCOUNT_FIELD, RFP_OPPORTUNITY_FIELD];
        return [];
    }

    // Pre-fill Account / Opportunity from the host record when possible.
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
            if (profileId) {
                this.selectedProfileId = profileId;
            }
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
                const defaultProfile = data.find(p => p.Is_Default__c);
                if (defaultProfile) {
                    this.selectedProfileId = defaultProfile.Id;
                }
            }
        }
    }

    get contextRecordId() {
        // lightning-file-upload requires a record to attach to.
        // Use the host record if available, or a placeholder — the real link
        // is made via ContentDocumentLink during initiateExtraction.
        return this.recordId ?? null;
    }

    get profileOptions() {
        return this.profiles.map(p => ({
            label: p.Name + (p.Is_Default__c ? ' (Default)' : ''),
            value: p.Id
        }));
    }

    get hasFile() {
        return !!this.uploadedFileId;
    }

    get accountFieldLabel() {
        return this.accountInferred ? 'Account (inherited)' : 'Account (optional)';
    }

    get opportunityFieldLabel() {
        return this.opportunityInferred ? 'Opportunity (inherited)' : 'Opportunity (optional)';
    }

    get submitDisabled() {
        return this.isBusy || !this.hasFile || !this.selectedProfileId;
    }

    get submitLabel() {
        return this.isBusy ? 'Starting…' : 'Start Extraction';
    }

    handleUploadFinished(event) {
        const file = event.detail.files[0];
        this.uploadedFileId = file.documentId;
        this.uploadedFileName = file.name;
        this.errorMessage = null;
    }

    handleRemoveFile() {
        this.uploadedFileId = null;
        this.uploadedFileName = '';
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
                rfpId: this.objectApiName === 'RFP__c' ? this.recordId : null,
                contentDocumentId: this.uploadedFileId,
                extractionProfileId: this.selectedProfileId,
                accountId: this.accountId,
                opportunityId: this.opportunityId
            });
            this.isDone = true;
        } catch (e) {
            this.errorMessage = e?.body?.message ?? e?.message ?? 'An error occurred.';
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
}
