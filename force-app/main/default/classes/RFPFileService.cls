public with sharing class RFPFileService {

    // Prompt Builder documents a 15 MB aggregate file limit and a maximum of
    // 10 image files per request.  We use the conservative count for the
    // complete record-bound corpus so a provider cannot reject a request after
    // the queueable has already made the LLM call.
    public static final Integer MAX_FILE_COUNT = 10;
    public static final Integer MAX_TOTAL_BYTES = 15728640;

    private static final Set<String> SUPPORTED_EXTENSIONS = new Set<String>{
        'pdf', 'png', 'jpeg', 'jpg'
    };

    public class FileInfo {
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public String fileExtension;
        @AuraEnabled public Integer contentSize;
        @AuraEnabled public Boolean supported;
        @AuraEnabled public String exclusionReason;

        public FileInfo() {}

        public FileInfo(Id documentId, String fileTitle, String extension, Integer size) {
            contentDocumentId = documentId;
            title = fileTitle;
            fileExtension = normalizeExtension(extension);
            contentSize = size;
            supported = isSupportedExtension(fileExtension);
            exclusionReason = supported ? null : 'Unsupported file type';
        }
    }

    public class CorpusValidation {
        public List<FileInfo> eligibleFiles = new List<FileInfo>();
        public List<FileInfo> excludedFiles = new List<FileInfo>();
        public Integer totalBytes = 0;

        public List<Id> eligibleDocumentIds() {
            List<Id> ids = new List<Id>();
            for (FileInfo file : eligibleFiles) {
                ids.add(file.contentDocumentId);
            }
            return ids;
        }

        public List<String> excludedFileNames() {
            List<String> names = new List<String>();
            for (FileInfo file : excludedFiles) {
                names.add(displayName(file));
            }
            return names;
        }
    }

    public class LinkResult {
        public List<Id> eligibleDocumentIds = new List<Id>();
        public List<Id> createdLinkIds = new List<Id>();
        public List<String> excludedFileNames = new List<String>();
    }

    /**
     * Returns the files visible through ContentDocumentLink for a parent.
     * This method deliberately reads only file metadata, never VersionData.
     */
    public static List<FileInfo> getFilesForParent(Id parentId) {
        if (parentId == null) {
            return new List<FileInfo>();
        }

        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId,
                       ContentDocument.Title,
                       ContentDocument.FileExtension
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :parentId
                ORDER BY ContentDocument.CreatedDate ASC
            ];

            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : links) {
                if (link.ContentDocumentId != null) {
                    documentIds.add(link.ContentDocumentId);
                }
            }

            Map<Id, ContentVersion> latestVersions = getLatestVersions(documentIds);
            List<FileInfo> files = new List<FileInfo>();
            Set<Id> seen = new Set<Id>();
            for (ContentDocumentLink link : links) {
                if (link.ContentDocumentId == null || seen.contains(link.ContentDocumentId)) {
                    continue;
                }
                seen.add(link.ContentDocumentId);

                ContentVersion version = latestVersions.get(link.ContentDocumentId);
                String title = link.ContentDocument?.Title;
                String extension = link.ContentDocument?.FileExtension;
                Integer size;
                if (version != null) {
                    title = String.isBlank(title) ? version.Title : title;
                    extension = String.isBlank(extension) ? version.FileExtension : extension;
                    size = version.ContentSize;
                }
                files.add(new FileInfo(link.ContentDocumentId, title, extension, size));
            }
            return files;
        } catch (Exception e) {
            throw new RFPExtractionException(
                'Unable to read linked Salesforce File metadata for record ' +
                parentId + ': ' + e.getMessage()
            );
        }
    }

    /**
     * Returns metadata for explicitly selected ContentDocument IDs.  Missing
     * or inaccessible IDs fail closed instead of silently shrinking the corpus.
     */
    public static List<FileInfo> getFilesByDocumentIds(List<Id> requestedIds) {
        List<Id> orderedIds = orderedUniqueDocumentIds(requestedIds);
        if (orderedIds.isEmpty()) {
            return new List<FileInfo>();
        }

        try {
            Map<Id, ContentDocument> documents = new Map<Id, ContentDocument>([
                SELECT Id, Title, FileExtension
                FROM ContentDocument
                WHERE Id IN :orderedIds
            ]);
            if (documents.size() != orderedIds.size()) {
                throw new RFPExtractionException(
                    'One or more selected Salesforce Files are unavailable or not readable.'
                );
            }

            Map<Id, ContentVersion> latestVersions = getLatestVersions(new Set<Id>(orderedIds));
            List<FileInfo> files = new List<FileInfo>();
            for (Id documentId : orderedIds) {
                ContentDocument document = documents.get(documentId);
                ContentVersion version = latestVersions.get(documentId);
                String title = document.Title;
                String extension = document.FileExtension;
                Integer size;
                if (version != null) {
                    title = String.isBlank(title) ? version.Title : title;
                    extension = String.isBlank(extension) ? version.FileExtension : extension;
                    size = version.ContentSize;
                }
                files.add(new FileInfo(documentId, title, extension, size));
            }
            return files;
        } catch (RFPExtractionException e) {
            throw e;
        } catch (Exception e) {
            throw new RFPExtractionException(
                'Unable to read selected Salesforce File metadata: ' + e.getMessage()
            );
        }
    }

    public static CorpusValidation validateRfpCorpus(Id rfpId) {
        return validateFiles(
            getFilesForParent(rfpId),
            'RFP ' + rfpId,
            true
        );
    }

    public static CorpusValidation validateSelectedDocuments(List<Id> documentIds) {
        return validateFiles(
            getFilesByDocumentIds(documentIds),
            'the selected Salesforce Files',
            true
        );
    }

    public static List<Id> getEligibleCaseDocumentIds(Id caseId) {
        Set<Id> linkedEntityIds = new Set<Id>{ caseId };
        for (EmailMessage email : [
            SELECT Id
            FROM EmailMessage
            WHERE ParentId = :caseId
              AND Incoming = true
        ]) {
            linkedEntityIds.add(email.Id);
        }

        CorpusValidation validation = validateFiles(
            getFilesForParents(linkedEntityIds),
            'Case ' + caseId,
            true
        );
        return validation.eligibleDocumentIds();
    }

    public static List<Id> getEligibleEmailDocumentIds(Id emailMessageId) {
        CorpusValidation validation = validateFiles(
            getFilesForParent(emailMessageId),
            'EmailMessage ' + emailMessageId,
            true
        );
        return validation.eligibleDocumentIds();
    }

    private static List<FileInfo> getFilesForParents(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty()) {
            return new List<FileInfo>();
        }

        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId,
                       ContentDocument.Title,
                       ContentDocument.FileExtension,
                       ContentDocument.CreatedDate
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :parentIds
                ORDER BY ContentDocument.CreatedDate ASC
            ];

            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : links) {
                documentIds.add(link.ContentDocumentId);
            }

            Map<Id, ContentVersion> latestVersions = getLatestVersions(documentIds);
            List<FileInfo> files = new List<FileInfo>();
            Set<Id> seen = new Set<Id>();
            for (ContentDocumentLink link : links) {
                if (!seen.add(link.ContentDocumentId)) {
                    continue;
                }
                ContentVersion version = latestVersions.get(link.ContentDocumentId);
                files.add(new FileInfo(
                    link.ContentDocumentId,
                    version == null ? link.ContentDocument.Title : version.Title,
                    version == null ? link.ContentDocument.FileExtension : version.FileExtension,
                    version?.ContentSize
                ));
            }
            return files;
        } catch (Exception e) {
            throw new RFPExtractionException(
                'Unable to read Salesforce File metadata for the Email-to-Case records: ' + e.getMessage()
            );
        }
    }

    /**
     * Bulk-links the supported subset of the requested documents and leaves
     * existing links untouched.  Unsupported files are returned as exclusions;
     * if they are the only requested files, validation throws instead.
     */
    public static LinkResult linkDocuments(Id parentId, List<Id> requestedIds) {
        if (parentId == null) {
            throw new RFPExtractionException('A parent record is required before linking Salesforce Files.');
        }

        LinkResult result = new LinkResult();
        List<Id> orderedIds = orderedUniqueDocumentIds(requestedIds);
        if (orderedIds.isEmpty()) {
            return result;
        }

        CorpusValidation validation = validateFiles(
            getFilesByDocumentIds(orderedIds),
            'the selected Salesforce Files',
            false
        );
        result.eligibleDocumentIds.addAll(validation.eligibleDocumentIds());
        result.excludedFileNames.addAll(validation.excludedFileNames());

        Set<Id> eligibleIds = new Set<Id>(result.eligibleDocumentIds);
        Set<Id> alreadyLinked = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT Id, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :parentId
              AND ContentDocumentId IN :eligibleIds
        ]) {
            alreadyLinked.add(link.ContentDocumentId);
        }

        List<ContentDocumentLink> toInsert = new List<ContentDocumentLink>();
        for (Id documentId : result.eligibleDocumentIds) {
            if (!alreadyLinked.contains(documentId)) {
                toInsert.add(new ContentDocumentLink(
                    ContentDocumentId = documentId,
                    LinkedEntityId = parentId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
            }
        }

        if (!toInsert.isEmpty()) {
            try {
                insert toInsert;
                for (ContentDocumentLink link : toInsert) {
                    result.createdLinkIds.add(link.Id);
                }
            } catch (Exception e) {
                throw new RFPExtractionException(
                    'Unable to link the selected Salesforce Files to record ' +
                    parentId + ': ' + e.getMessage()
                );
            }
        }
        return result;
    }

    /**
     * Removes only links created for this upload session.  The caller supplies
     * the document IDs that were already linked when the session began; those
     * IDs are always preserved.  ContentDocument records are never deleted.
     */
    public static void removeSessionLinks(
        Id rfpId,
        List<Id> sessionDocumentIds,
        List<Id> preExistingDocumentIds
    ) {
        if (rfpId == null || sessionDocumentIds == null || sessionDocumentIds.isEmpty()) {
            return;
        }

        Set<Id> removableIds = new Set<Id>(orderedUniqueDocumentIds(sessionDocumentIds));
        removableIds.removeAll(new Set<Id>(orderedUniqueDocumentIds(preExistingDocumentIds)));
        if (removableIds.isEmpty()) {
            return;
        }

        List<ContentDocumentLink> links = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :rfpId
              AND ContentDocumentId IN :removableIds
        ];
        if (!links.isEmpty()) {
            delete links;
        }
    }

    @TestVisible
    private static CorpusValidation validateFilesForTest(
        List<FileInfo> files,
        String context
    ) {
        return validateFiles(files, context, true);
    }

    private static CorpusValidation validateFiles(
        List<FileInfo> files,
        String context,
        Boolean requireAtLeastOne
    ) {
        CorpusValidation validation = new CorpusValidation();
        if (files == null) {
            files = new List<FileInfo>();
        }

        for (FileInfo file : files) {
            file.fileExtension = normalizeExtension(file.fileExtension);
            file.supported = isSupportedExtension(file.fileExtension);
            if (!file.supported) {
                file.exclusionReason = 'Unsupported file type';
                validation.excludedFiles.add(file);
                continue;
            }
            if (file.contentSize == null || file.contentSize < 0) {
                throw new RFPExtractionException(
                    'Unable to read the size of supported Salesforce File ' +
                    displayName(file) + ' for ' + context + '.'
                );
            }
            validation.eligibleFiles.add(file);
            validation.totalBytes += file.contentSize;
        }

        if (requireAtLeastOne && validation.eligibleFiles.isEmpty()) {
            String excluded = validation.excludedFileNames().isEmpty()
                ? ''
                : ' Excluded files: ' + String.join(validation.excludedFileNames(), ', ') + '.';
            throw new RFPExtractionException(
                'No supported Salesforce Files are available for ' + context +
                '. Attach a PDF, PNG, JPEG, or JPG before starting extraction.' + excluded
            );
        }
        if (validation.eligibleFiles.size() > MAX_FILE_COUNT) {
            throw new RFPExtractionException(
                'The supported Salesforce File corpus for ' + context +
                ' contains ' + validation.eligibleFiles.size() +
                ' files; the Prompt Builder limit is ' + MAX_FILE_COUNT + '.'
            );
        }
        if (validation.totalBytes > MAX_TOTAL_BYTES) {
            throw new RFPExtractionException(
                'The supported Salesforce File corpus for ' + context +
                ' is ' + validation.totalBytes + ' bytes; the Prompt Builder aggregate limit is ' +
                MAX_TOTAL_BYTES + ' bytes.'
            );
        }
        return validation;
    }

    private static Map<Id, ContentVersion> getLatestVersions(Set<Id> documentIds) {
        Map<Id, ContentVersion> latestVersions = new Map<Id, ContentVersion>();
        if (documentIds == null || documentIds.isEmpty()) {
            return latestVersions;
        }
        for (ContentVersion version : [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds
              AND IsLatest = true
        ]) {
            latestVersions.put(version.ContentDocumentId, version);
        }
        return latestVersions;
    }

    private static List<Id> orderedUniqueDocumentIds(List<Id> requestedIds) {
        List<Id> orderedIds = new List<Id>();
        Set<Id> seen = new Set<Id>();
        if (requestedIds == null) {
            return orderedIds;
        }
        for (Id documentId : requestedIds) {
            if (documentId == null) {
                continue;
            }
            if (documentId.getSObjectType() != ContentDocument.SObjectType) {
                throw new RFPExtractionException(
                    'Selected file ID ' + documentId + ' is not a ContentDocument ID.'
                );
            }
            if (seen.add(documentId)) {
                orderedIds.add(documentId);
            }
        }
        return orderedIds;
    }

    private static Boolean isSupportedExtension(String extension) {
        return !String.isBlank(extension) &&
            SUPPORTED_EXTENSIONS.contains(normalizeExtension(extension));
    }

    private static String normalizeExtension(String extension) {
        return String.isBlank(extension)
            ? null
            : extension.trim().toLowerCase().removeStart('.');
    }

    private static String displayName(FileInfo file) {
        return String.isBlank(file.title)
            ? String.valueOf(file.contentDocumentId)
            : file.title;
    }
}
