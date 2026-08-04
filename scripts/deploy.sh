#!/usr/bin/env bash
set -euo pipefail

TARGET_ORG="${1:-}"

# Preflight checks
if ! command -v sf &> /dev/null; then
  echo "Error: Salesforce CLI (sf) not found."
  echo "Install: https://developer.salesforce.com/tools/salesforcecli"
  exit 1
fi

if [[ -z "$TARGET_ORG" ]]; then
  echo "Usage: ./scripts/deploy.sh <target-org-alias-or-username>"
  echo ""
  echo "  Authenticate first:  sf org login web --alias <alias>"
  echo "  List orgs:           sf org list"
  exit 1
fi

echo "→ Verifying org connection..."
if ! sf org display --target-org "$TARGET_ORG" &> /dev/null; then
  echo "Error: Cannot connect to org '$TARGET_ORG'."
  echo "  Make sure it's authenticated:  sf org login web --alias $TARGET_ORG"
  exit 1
fi

# Step 1: Deploy all custom objects first.
# Two reasons: (1) RFP__c.enableFeeds=true must be live in the org before the
# layout validator will accept the RelatedFileList component. (2) lookup fields
# on RFP__c reference Extraction_Profile__c, so all objects must exist before
# the full source deploy validates field references.
echo "→ [1/4] Deploying objects, Apex, LWC, and record pages (prerequisite for layouts)"
# Two reasons for this pre-pass:
# (1) RFP__c.enableFeeds=true must be live before the layout validator accepts RelatedFileList.
# (2) Object actionOverrides reference FlexiPages; FlexiPages reference LWC components and
#     Apex classes. Everything must land in one batch so the deployment engine can order them
#     correctly (objects → Apex → LWC → FlexiPage). RFP_Agent_Home_Page is excluded here
#     because it depends on the dashboard, which is deployed in step 2.
sf project deploy start \
  --metadata "CustomObject:RFP__c" \
             "CustomObject:Extraction_Profile__c" \
             "CustomObject:Extraction_Question__c" \
             "CustomObject:Extraction_Result__c" \
             "CustomObject:RFP_Extraction_Complete__e" \
             "ApexClass:RFPController" \
             "ApexClass:RFPExtractionAction" \
             "ApexClass:RFPExtractionQueueable" \
             "ApexClass:RFPExtractionException" \
             "ApexClass:RFPResultParser" \
             "ApexClass:RFPFileService" \
             "ApexClass:RFPFinalizationService" \
             "ApexClass:RFPInstallHandler" \
             "StaticResource:AgentforceGuy" \
             "LightningComponentBundle:rfpUploadAction" \
             "LightningComponentBundle:rfpExtractionReview" \
             "LightningComponentBundle:rfpConfidenceBadge" \
             "LightningComponentBundle:rfpResultField" \
             "FlexiPage:RFP_Record_Page" \
             "FlexiPage:Extraction_Profile_Record_Page" \
             "FlexiPage:Extraction_Question_Record_Page" \
             "FlexiPage:Extraction_Result_Record_Page" \
  --target-org "$TARGET_ORG" \
  --wait 30 \
  --concise

echo "→ [2/4] Deploying full source"
sf project deploy start \
  --source-dir force-app \
  --target-org "$TARGET_ORG" \
  --wait 30 \
  --concise

echo "→ [3/4] Deploying Account page layout (SDO orgs only — skipped if not applicable)"
sf project deploy start \
  --source-dir optional \
  --target-org "$TARGET_ORG" \
  --wait 10 \
  --concise 2>&1 || echo "  Account layout not applicable for this org — users can assign a layout manually in Setup."

echo "→ [4/4] Assigning permission sets"
sf org assign permset \
  --name RFP_Agent \
  --target-org "$TARGET_ORG" || echo "  (already assigned — skipping)"

sf org assign permset \
  --name EinsteinGPTPromptTemplateUser \
  --target-org "$TARGET_ORG" || echo "  (already assigned — skipping)"

echo "→ Seeding default extraction profile"
_seed_log=$(mktemp)
if sf apex run \
  --file "$(dirname "$0")/seed_default_profile.apex" \
  --target-org "$TARGET_ORG" > "$_seed_log" 2>&1; then
  echo "  ✓ Default profile seeded"
else
  echo "  ✗ Seed failed:"
  cat "$_seed_log"
  rm -f "$_seed_log"
  exit 1
fi
rm -f "$_seed_log"

echo ""
echo "✓ Deployment, permission assignment, and default-profile seed complete."
echo ""
echo "Manual if needed:"
echo "  Activate RFP_Email_Case_Auto_Extraction in Setup → Flows for email-triggered extraction."
echo ""
echo "Optional:"
echo "  ./scripts/seed_default_profile.sh $TARGET_ORG"
