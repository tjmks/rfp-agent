import { LightningElement, api } from 'lwc';

export default class RfpConfidenceBadge extends LightningElement {
    @api score;

    get hasScore() {
        return this.score != null;
    }

    get formattedScore() {
        return Math.round(this.score) + '%';
    }

    get title() {
        return `Confidence: ${this.formattedScore}`;
    }

    get badgeClass() {
        const s = this.score;
        if (s >= 80) return 'badge badge_success';
        if (s >= 60) return 'badge badge_warning';
        return 'badge badge_error';
    }
}
