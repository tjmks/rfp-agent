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

These two identifiers refer to the same file-related surface but use different names depending on context. `CombinedAttachments` is the Prompt Builder related-list provider name; it is not the value to use in layout XML. `ContentDocumentLinks`, `Attachments`, and `NotesAndAttachments` also fail in layout XML.

`RelatedFileList` in the layout also requires `<enableFeeds>true</enableFeeds>` on the object — the layout validator rejects it until feeds are enabled in the org.

---

## Deploy Order: enableFeeds + Layout + FlexiPage

When adding the Files related list to a custom object for the first time, a single-batch deploy of all three components fails because the layout validator checks whether feeds are enabled at validation time, not just at apply time.

**Required dependency:** `<enableFeeds>true</enableFeeds>` must be live before a
layout containing `RelatedFileList` is validated. The repository's validated
deployment script satisfies this with two passes:

1. Deploy the custom objects, Apex classes, LWCs, and record pages. This makes
   `RFP__c.enableFeeds=true` live and resolves the page/component references.
2. Deploy the full source, which adds the layouts (including `RelatedFileList`),
   prompt templates, Flow, app, dashboard, reports, tabs, and permission set.

For a smaller standalone deployment, deploy the object first and the layout
afterward. Once `enableFeeds` is already live in the org, later changes can be
deployed together.

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

The home FlexiPage must be available when the CustomApplication is applied. The
repo deploys `RFP_Agent_Home_Page` with the full source after its dashboard
dependency is available; in a separate deployment, deploy the FlexiPage before
the app.

---

## FlexiPage Deploy Order

When deploying FlexiPages that contain related lists for the first time, include
them in the prerequisite batch with the objects and their referenced Apex/LWC
components. Deploying the page before those dependencies are available can
leave references unresolved in the deployment validator.

In practice, use the repository's first pass in `scripts/deploy.sh`, or put
custom objects, their FlexiPages, and Apex/LWC into a single
`sf project deploy start --metadata` call. The later full-source pass is where
the Files-bearing layouts are applied after `enableFeeds` is live.

---

## Lightning App Requirements

A Custom Application (`.app-meta.xml`) requires `<formFactors>` to be deployable to a Lightning org:

```xml
<formFactors>Large</formFactors>
<formFactors>Small</formFactors>
```

Omitting these causes the deploy to fail with a validator error even if the app otherwise looks valid.

---

## Prompt Builder related-list grounding

The RFP templates use the parent input alias in the related-list expression:

```text
{!$RelatedList:RFPRecord.CombinedAttachments.Records}
```

The template provider receives the `RFP__c` ID through `RFPRecord` and resolves
the `CombinedAttachments` list. The object-qualified expression
`{!$RelatedList:RFP__c.CombinedAttachments.Records}` was rejected by Metadata
API validation in the validated org. Related-list fields are taken from the
parent page layout for the current user, so the Files related list and file
visibility must be available to the runtime user. The application still
validates supported extensions, count, and aggregate size before the model call.
