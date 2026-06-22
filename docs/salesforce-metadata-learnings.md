# Salesforce Metadata Deployment Learnings

Practical lessons learned building and deploying this project — each backed by a deploy failure that revealed the rule.

---

## Related Lists in Page Layout XML

### Custom-to-custom related lists

The Metadata API rejects the relationship name alone. The correct format is:

```xml
<relatedLists>
    <fields>NAME</fields>
    <fields>Status__c</fields>
    <relatedList>ChildObject__c.LookupFieldOnChild__c</relatedList>
</relatedLists>
```

Use `ObjectApiName.LookupFieldApiName` — not the relationship name (`ChildObjects__r`). Discovered by comparing a working org's deployed layout XML.

### The `Name` field in related list columns

`<fields>Name</fields>` is rejected with "Invalid field: Name". The correct value is `<fields>NAME</fields>` (all caps).

### Files related list

Files cannot be added to a custom object layout using standard attachment names. The platform-specific values are:

| Context | Correct value |
|---|---|
| `<relatedList>` in layout XML | `RelatedFileList` |
| `relatedListApiName` in FlexiPage | `AttachedContentDocuments` |

These two identifiers refer to the same related list but use different names depending on context. `CombinedAttachments`, `ContentDocumentLinks`, `Attachments`, `NotesAndAttachments` all fail in layout XML.

`RelatedFileList` in the layout also requires `<enableFeeds>true</enableFeeds>` on the object — the layout validator rejects it until feeds are enabled in the org.

---

## Deploy Order: enableFeeds + Layout + FlexiPage

When adding the Files related list to a custom object for the first time, a single-batch deploy of all three components fails because the layout validator checks whether feeds are enabled at validation time, not just at apply time.

**Required sequence:**

1. Deploy the object with `<enableFeeds>true</enableFeeds>` alone
2. Deploy the layout (with `RelatedFileList`) and the FlexiPage (with `AttachedContentDocuments`) together

Once `enableFeeds` is already live in the org, subsequent deploys can include all three together.

---

## Record Page Assignment as Org Default

The FlexiPage activation (what Lightning App Builder calls "Assign as Org Default") is stored on the **CustomObject**, not on the FlexiPage. It is fully deployable via `actionOverrides` in the object's `.object-meta.xml`.

```xml
<actionOverrides>
    <actionName>View</actionName>
    <content>MyObject_Record_Page</content>
    <formFactor>Large</formFactor>
    <type>Flexipage</type>
</actionOverrides>
<actionOverrides>
    <actionName>View</actionName>
    <content>MyObject_Record_Page</content>
    <formFactor>Small</formFactor>
    <type>Flexipage</type>
</actionOverrides>
```

Both `Large` (desktop) and `Small` (phone) form factors are required — omitting either leaves that form factor unassigned. No manual post-deploy step needed.

---

## App Home Page Assignment

The home tab page assignment is stored on the **CustomApplication**, not on the FlexiPage. Add an `actionOverrides` block to the app's `.app-meta.xml`:

```xml
<actionOverrides>
    <actionName>Tab</actionName>
    <content>RFP_Agent_Home_Page</content>
    <formFactor>Large</formFactor>
    <pageOrSobjectType>standard-home</pageOrSobjectType>
    <type>Flexipage</type>
</actionOverrides>
```

`Small` is not supported for `Tab` overrides and will fail deployment. Only `Large` is valid here.

The FlexiPage must already exist in the org when the CustomApplication deploys — deploy them together or the FlexiPage first.

---

## FlexiPage Deploy Order

When deploying FlexiPages that contain related lists for the first time, include them in the same deploy batch as the objects. Deploying FlexiPages after objects in a subsequent step can leave the page referencing relationships that aren't yet resolved in the org's component registry.

In practice: put custom objects, their FlexiPages, and Apex/LWC into a single `sf project deploy start --metadata` call or use `--source-dir force-app` to deploy everything together.

---

## Lightning App Requirements

A Custom Application (`.app-meta.xml`) requires `<formFactors>` to be deployable to a Lightning org:

```xml
<formFactors>Large</formFactors>
<formFactors>Small</formFactors>
```

Omitting these causes the deploy to fail with a validator error even if the app otherwise looks valid.
