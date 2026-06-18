public class RFPInstallHandler implements InstallHandler {

    private static final String WEBHOOK_URL = 'https://script.google.com/a/macros/salesforce.com/s/AKfycbzthoIlKbC7PI5q4-lwtT7SIGUnZU5BGg4xPtmdnwb5w6oaXShvVA7S_mj2_OxMdZHQ/exec';
    // Update VERSION to match the package version before running sf package version create
    private static final String VERSION = '1.0.0';

    public void onInstall(InstallContext context) {
        String orgId = String.valueOf(context.organizationId());
        String orgName = [SELECT Name FROM Organization LIMIT 1].Name;
        String installDate = String.valueOf(Date.today());
        sendInstallPing(orgId, orgName, installDate);
    }

    @future(callout=true)
    private static void sendInstallPing(String orgId, String orgName, String installDate) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(WEBHOOK_URL);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, String>{
            'orgId'       => orgId,
            'orgName'     => orgName,
            'version'     => VERSION,
            'installDate' => installDate
        }));
        req.setTimeout(10000);
        try {
            new Http().send(req);
        } catch (Exception e) {
            // Silent fail — never block the install
        }
    }
}
