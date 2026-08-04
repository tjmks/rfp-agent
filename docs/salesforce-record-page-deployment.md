# Salesforce Record Page Deployment Guide

This guide covers how to build, configure, and deploy Salesforce record pages with related lists, page layouts, org-wide defaults, and permission sets. The examples are drawn from this repo; the final section matches the staged behavior of `scripts/deploy.sh`.

---

## 1. FlexiPage — Record Page Structure

Record pages are defined as `.flexipage-meta.xml` files in `force-app/main/default/flexipages/`.

### Adding a Specific Related List

Use the `force:relatedListSingleContainer` component to add one named related list to a region:

```xml
<flexiPageRegions>
    <itemInstances>
        <componentInstance>
            <componentInstanceProperties>
                <name>parentFieldApiName</name>
                <value>RFP__c.Id</value>
            </componentInstanceProperties>
            <componentInstanceProperties>
                <name>relatedListApiName</name>
                <value>Extraction_Results__r</value>
            </componentInstanceProperties>
            <componentInstanceProperties>
                <name>relatedListComponentOverride</name>
                <value>NONE</value>
            </componentInstanceProperties>
            <componentInstanceProperties>
                <name>rowsToDisplay</name>
                <value>10</value>
            </componentInstanceProperties>
            <componentInstanceProperties>
                <name>showActionBar</name>
                <value>true</value>
            </componentInstanceProperties>
            <componentName>force:relatedListSingleContainer</componentName>
            <identifier>force_relatedListSingle_extractionResults</identifier>
        </componentInstance>
    </itemInstances>
    <name>facet_related</name>
    <type>Facet</type>
</flexiPageRegions>
```

**Property reference:**

| Property | Value | Notes |
|---|---|---|
| `parentFieldApiName` | `ParentObject__c.Id` | The parent object and `Id` field |
| `relatedListApiName` | `ChildRecords__r` | Relationship API name (the `__r` suffix) |
| `relatedListComponentOverride` | `NONE` | Use `NONE` for standard rendering |
| `rowsToDisplay` | `10` | Number of rows shown before "View All" |
| `showActionBar` | `true` | Whether to show New/Edit buttons |

- `identifier` must be unique within the FlexiPage — use a snake_case string describing the list.
- Add multiple `<componentInstance>` blocks within the same region to stack several related lists.

### Adding All Related Lists (Auto)

Use `force:relatedListContainer` (no "Single") to render all standard related lists automatically without specifying each one:

```xml
<componentInstance>
    <componentInstanceProperties>
        <name>relatedListComponentOverride</name>
        <value>NONE</value>
    </componentInstanceProperties>
    <componentName>force:relatedListContainer</componentName>
    <identifier>force_relatedListContainer</identifier>
</componentInstance>
```

Use this when you want the standard "Related" tab experience without controlling which lists appear.

---

## 2. Page Layouts — Adding Related Lists

Layout files live at `force-app/main/default/layouts/<ObjectApiName>-<LayoutName>.layout-meta.xml`.

Add a `<relatedLists>` block for each related list you want to appear:

```xml
<relatedLists>
    <fields>NAME</fields>
    <fields>Field_Label__c</fields>
    <fields>Extracted_Value__c</fields>
    <fields>Review_Status__c</fields>
    <relatedList>Extraction_Result__c.RFP__c</relatedList>
</relatedLists>
```

### Key rules

- **`<relatedList>` format for custom-to-custom relationships:** `ChildObject__c.LookupField__c`
  - This is `<child object API name>.<lookup field API name on that child>`, not a relationship name.
  - Example: a child `Extraction_Result__c` with a lookup `RFP__c` → `Extraction_Result__c.RFP__c`
- **Standard related lists** use short names, not the dot-notation: `RelatedFileList`, `RelatedActivityList`, `RelatedHistoryList`
- **`<fields>`** lists the columns shown in the related list. Use API names; `NAME` is the standard name field shorthand.
- Order of `<relatedLists>` blocks in the XML determines display order on the layout.

### Common standard related list names

| Name | What it shows |
|---|---|
| `RelatedFileList` | Files/Attachments |
| `RelatedActivityList` | Open Activities |
| `RelatedHistoryList` | Activity History |

---

## 3. Assigning a Record Page as Org-Wide Default

Do **not** use a separate RecordPageAssignment file. Set `<actionOverrides>` directly in the object's `.object-meta.xml` file at `force-app/main/default/objects/<ObjectApiName>/<ObjectApiName>.object-meta.xml`.

```xml
<actionOverrides>
    <actionName>View</actionName>
    <type>Default</type>
</actionOverrides>
<actionOverrides>
    <actionName>View</actionName>
    <content>RFP_Record_Page</content>
    <formFactor>Large</formFactor>
    <type>Flexipage</type>
</actionOverrides>
<actionOverrides>
    <actionName>View</actionName>
    <content>RFP_Record_Page</content>
    <formFactor>Small</formFactor>
    <type>Flexipage</type>
</actionOverrides>
```

- `<content>` is the FlexiPage **API name** (the filename without `.flexipage-meta.xml`).
- Provide one `<actionOverride>` for `formFactor=Large` (desktop) and one for `formFactor=Small` (mobile).
- The `<type>Default</type>` block must also be present as a fallback.
- Because this is in the object metadata itself, it deploys automatically with `sf project deploy` — no post-deploy Apex needed.

> **Why this works at org level:** Action overrides on an object with no profile/app scope set apply org-wide. There is no FlexiPage API for setting org-default programmatically; the object-level action override is the correct metadata approach.

### App-level home page assignment

For app home pages, the override goes in the `.app-meta.xml` file instead:

```xml
<actionOverrides>
    <actionName>Tab</actionName>
    <content>RFP_Agent_Home_Page</content>
    <formFactor>Large</formFactor>
    <pageOrSobjectType>standard-home</pageOrSobjectType>
    <type>Flexipage</type>
</actionOverrides>
```

---

## 4. Permission Sets

Permission set files live at `force-app/main/default/permissionsets/<Name>.permissionset-meta.xml`.

A complete permission set for a record-page-driven app typically grants:

### App and tab visibility

```xml
<applicationVisibilities>
    <application>RFP_App</application>
    <visible>true</visible>
</applicationVisibilities>
<tabSettings>
    <tab>RFP__c</tab>
    <visibility>Visible</visibility>
</tabSettings>
```

### Object permissions

```xml
<objectPermissions>
    <allowCreate>true</allowCreate>
    <allowDelete>true</allowDelete>
    <allowEdit>true</allowEdit>
    <allowRead>true</allowRead>
    <modifyAllRecords>false</modifyAllRecords>
    <object>RFP__c</object>
    <viewAllRecords>false</viewAllRecords>
</objectPermissions>
```

### Field-level security

Fields are either editable or read-only. Fields not listed receive no access from
this permission set; a profile or another permission set may still grant access.

```xml
<fieldPermissions>
    <editable>true</editable>
    <field>RFP__c.Account__c</field>
    <readable>true</readable>
</fieldPermissions>
<fieldPermissions>
    <editable>false</editable>
    <field>RFP__c.Processing_Status__c</field>
    <readable>true</readable>
</fieldPermissions>
```

### Apex class access

Any controller or service class invoked from LWC or Flow must be explicitly listed:

```xml
<classAccesses>
    <apexClass>RFPController</apexClass>
    <enabled>true</enabled>
</classAccesses>
```

### Assigning permission sets on deploy

Assign via the CLI after deploying metadata. In `scripts/deploy.sh`:

```bash
sf org assign permset --name RFP_Agent --target-org "$TARGET_ORG"
sf org assign permset --name EinsteinGPTPromptTemplateUser --target-org "$TARGET_ORG"
```

- Assign all custom permission sets and the org's Prompt Builder execution permission (the repository script attempts `EinsteinGPTPromptTemplateUser`; current orgs may expose the equivalent `Execute Prompt Templates` permission through Prompt Template Manager).
- This step must run after the full metadata deploy so the permission set metadata exists in the org.

---

## 5. Deployment Order

Some metadata types depend on others. The repository's staged order is:

1. **Prerequisite pass** — custom objects, platform event, Apex classes, static resource, LWCs, and record pages. This makes `RFP__c.enableFeeds=true` live before the Files-bearing layout is validated.
2. **Full source pass** — layouts, prompt templates, Flow, app/home page, permission set, tabs, dashboard, and reports.
3. **Optional source pass** — the Account layout under `optional/`, which is only applicable in orgs that contain the referenced SDO metadata.
4. **Assign permission sets** — run `sf org assign permset` after metadata is in the org.
5. **Seed data** — refresh the default extraction profile with anonymous Apex.

The first two passes are implemented in `scripts/deploy.sh` as:

```bash
# Pass 1: prerequisite metadata
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
  --target-org "$TARGET_ORG" --wait 30 --concise

# Pass 2: everything else
sf project deploy start \
  --source-dir force-app \
  --target-org "$TARGET_ORG" --wait 30 --concise
```

The script then attempts the `optional/` Account-layout deploy, assigns
`RFP_Agent` and `EinsteinGPTPromptTemplateUser`, and runs
`scripts/seed_default_profile.apex`.

---

## 6. File Reference Summary

| What | Where |
|---|---|
| Record pages | `force-app/main/default/flexipages/*.flexipage-meta.xml` |
| Page layouts | `force-app/main/default/layouts/*.layout-meta.xml` |
| Org-default page assignment | `force-app/main/default/objects/<Obj>/<Obj>.object-meta.xml` (`<actionOverrides>`) |
| Permission sets | `force-app/main/default/permissionsets/*.permissionset-meta.xml` |
| Deploy script | `scripts/deploy.sh` |
| Post-install handler | `force-app/main/default/classes/RFPInstallHandler.cls` |
