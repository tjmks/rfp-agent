// Seeds (or refreshes) a Salesforce Service RFP profile calibrated with the
// BIKE24 helpdesk-system RFP as an example sender context.
// Idempotent: re-running deletes the profile's existing questions and reinserts them.

String PROFILE_NAME = 'Salesforce Service RFP - Retail';

String grounding = String.join(new List<String>{
    'Evaluator company: Salesforce',
    'Purpose of this profile: Help Salesforce evaluate incoming RFPs from online retailers and other customer-service organizations that are procuring a modern service, helpdesk, contact-center, workforce, reporting, knowledge, automation, or AI-enabled customer engagement platform. BIKE24 GmbH, a German online retailer for bike parts, is the example sender context used to calibrate the profile, but the questions are reusable for similar RFPs.',
    '',
    'Company snapshot:',
    '- Salesforce provides CRM and customer engagement applications on a unified cloud platform, including Sales, Service, Marketing, Commerce, Data Cloud, Tableau, MuleSoft, Slack, and Agentforce capabilities.',
    '- For service and support use cases, Salesforce Service Cloud is positioned around case management, omni-channel support, knowledge, automation, analytics, and an AI-powered agent console.',
    '- Salesforce operates globally and commonly responds to enterprise requirements involving security, privacy, governance, implementation partners, integration, scalability, and measurable business outcomes.',
    '',
    'Relevant offerings and capabilities:',
    '- Service Cloud can address case and ticket management, agent workspace, omni-channel routing, knowledge, service analytics, workflow automation, self-service, and contact center integration patterns.',
    '- Agentforce and Salesforce AI capabilities are relevant when RFPs ask for agent assist, automation of repetitive contacts, conversational service, knowledge recommendations, productivity gains, and quality or summarization support.',
    '- MuleSoft and Salesforce APIs are relevant when RFPs ask for integration with ERP, commerce, telephony, identity, warehouse, product, order, payment, or legacy ticketing systems.',
    '- Data Cloud, CRM data, and analytics capabilities are relevant when RFPs ask for unified customer profiles, service history, segmentation, dashboards, or AI grounded in trusted customer context.',
    '- Salesforce has a broad partner ecosystem for implementation, migration, change management, localization, and industry-specific delivery.',
    '',
    'Customer and market evidence:',
    '- Salesforce publishes Service Cloud, trust, privacy, compliance, and customer-story material that can support claims about service operations, productivity, customer loyalty, security, privacy, and global deployment.',
    '- Public Salesforce customer stories span large enterprises and consumer-facing businesses; use only public and relevant proof points when recommending response evidence.',
    '',
    'Likely strengths in RFP responses:',
    '- Strong fit when the RFP asks for a unified agent desktop, CRM-connected service history, omni-channel case handling, reporting at management/supervisor/agent levels, workflow automation, AI-assisted service, knowledge management, and integration with existing systems.',
    '- Strong fit when the buyer values roadmap depth, platform extensibility, enterprise security, privacy documentation, partner delivery capacity, and a phased implementation model.',
    '',
    'Known gaps, caveats, or assumptions:',
    '- This profile assumes the opportunity is centered on Service Cloud, contact center integration, AI-assisted service, analytics, and related platform capabilities for retailers or service organizations.',
    '- Workforce management, native telephony/ACD, and some channel-specific capabilities may require Salesforce add-ons, AppExchange partners, telephony partners, or implementation scoping rather than only core Service Cloud.',
    '- Pricing, licensing mix, data residency, German-language delivery, and detailed GDPR/AVV commitments must be validated against the actual RFP and the proposed Salesforce commercial architecture.',
    '',
    'How to use this context:',
    '- Use it for fit, risk, win theme, proof-point, and response strategy recommendations.',
    '- Do not treat this context as content from the RFP document.'
}, '\n');

Extraction_Profile__c profile;
List<Extraction_Profile__c> existing = [
    SELECT Id FROM Extraction_Profile__c WHERE Name = :PROFILE_NAME LIMIT 1
];

if (existing.isEmpty()) {
    profile = new Extraction_Profile__c(Name = PROFILE_NAME);
} else {
    profile = existing[0];
}

profile.Description__c = 'Salesforce service-platform RFP profile calibrated for online retail and customer-service modernization opportunities such as BIKE24.';
profile.Grounding_Context__c = grounding;
profile.Is_Active__c = true;
profile.Is_Default__c = false;
profile.Extraction_Template__c = null;
profile.Reasoning_Template__c = null;

if (existing.isEmpty()) {
    insert profile;
} else {
    update profile;
    delete [SELECT Id FROM Extraction_Question__c WHERE Extraction_Profile__c = :profile.Id];
}

String wordCap = '\n\nLimit your answer to 250 words or fewer.';

List<Map<String, Object>> rows = new List<Map<String, Object>>{
    new Map<String, Object>{
        'name' => 'Project or Solicitation Title',
        'text' => 'What is the official title or name of the RFP, project, solicitation, or procurement?',
        'type' => 'Extraction', 'output' => 'Text', 'category' => 'Overview', 'sort' => 10, 'required' => true, 'threshold' => 80,
        'hint' => 'Use the cover page or header where available.'
    },
    new Map<String, Object>{
        'name' => 'Issuing Organization',
        'text' => 'What organization is issuing the RFP? Return the legal entity name and country or region if stated.',
        'type' => 'Extraction', 'output' => 'Text', 'category' => 'Overview', 'sort' => 20, 'required' => true, 'threshold' => 80,
        'hint' => 'This is the buyer/prospect, not Salesforce.'
    },
    new Map<String, Object>{
        'name' => 'Sender Industry and Business Context',
        'text' => 'What industry, business model, customer-service environment, and operational context does the RFP describe for the issuing organization?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Overview', 'sort' => 30, 'required' => false, 'threshold' => 70,
        'hint' => 'Examples: online retail, B2C ecommerce, multi-market support, growth pressure, fragmented tooling.'
    },
    new Map<String, Object>{
        'name' => 'Submission and Q&A Deadlines',
        'text' => 'Extract all stated proposal submission, Q&A, intent-to-bid, demo, vendor-selection, and project-start deadlines. Include dates and labels exactly as stated.',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Timeline', 'sort' => 40, 'required' => true, 'threshold' => 80,
        'hint' => 'Return every milestone, not just the final due date.'
    },
    new Map<String, Object>{
        'name' => 'Scope and Project Phases',
        'text' => 'Summarize the requested scope and any phased rollout. Separate in-scope current phase requirements from later-phase or optional roadmap items.',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Scope', 'sort' => 50, 'required' => true, 'threshold' => 75,
        'hint' => 'Useful for separating phase 1 commitments from future AI, knowledge, or channel roadmap items.'
    },
    new Map<String, Object>{
        'name' => 'Current Systems and Replacement Scope',
        'text' => 'What current systems, tools, spreadsheets, channels, or manual processes does the RFP say should be replaced, integrated, migrated, or retained?',
        'type' => 'Extraction', 'output' => 'List', 'category' => 'Current State', 'sort' => 60, 'required' => false, 'threshold' => 75,
        'hint' => 'Include ticketing, telephony, workforce planning, reporting, knowledge, commerce, CRM, identity, and data sources if mentioned.'
    },
    new Map<String, Object>{
        'name' => 'Required Service Capabilities',
        'text' => 'List the required service-platform capabilities. Include case or ticket management, unified agent desktop, omni-channel, routing, workflow, SLA, escalation, automation, customer history, and agent productivity requirements when stated.',
        'type' => 'Extraction', 'output' => 'List', 'category' => 'Requirements', 'sort' => 70, 'required' => true, 'threshold' => 75,
        'hint' => 'Use the RFP wording where practical.'
    },
    new Map<String, Object>{
        'name' => 'Contact Center and Telephony Requirements',
        'text' => 'What telephony, ACD, call routing, CTI, voice, video, recording, callback, or contact-center integration requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Requirements', 'sort' => 80, 'required' => false, 'threshold' => 70,
        'hint' => 'Capture whether telephony must be native, integrated, replaced, or phased.'
    },
    new Map<String, Object>{
        'name' => 'Workforce Management Requirements',
        'text' => 'What workforce management, scheduling, shift planning, intraday management, forecasting, capacity planning, or agent self-service requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Requirements', 'sort' => 90, 'required' => false, 'threshold' => 70,
        'hint' => 'Important because WFM may be core, partner, or integration-led depending on the proposed architecture.'
    },
    new Map<String, Object>{
        'name' => 'Reporting and Analytics Requirements',
        'text' => 'What reporting, dashboard, KPI, analytics, supervisor, management, agent, AI reporting, or performance measurement requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Requirements', 'sort' => 100, 'required' => true, 'threshold' => 75,
        'hint' => 'Include named KPI levels, roles, and expected reporting audiences.'
    },
    new Map<String, Object>{
        'name' => 'Customer Data and Integration Requirements',
        'text' => 'What customer data, service history, unified profile, API, ERP, commerce, identity, data migration, or system integration requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Architecture', 'sort' => 110, 'required' => true, 'threshold' => 75,
        'hint' => 'Look for CRM fit, MuleSoft/API needs, and data-model dependencies.'
    },
    new Map<String, Object>{
        'name' => 'AI Automation and Knowledge Requirements',
        'text' => 'What requirements or roadmap items mention AI, agent assist, automation, knowledge base, semantic suggestions, self-service, chatbots, deflection, or handling repetitive contacts?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'AI and Knowledge', 'sort' => 120, 'required' => false, 'threshold' => 70,
        'hint' => 'Separate mandatory current-phase requirements from later roadmap requirements.'
    },
    new Map<String, Object>{
        'name' => 'Security Privacy and Compliance Requirements',
        'text' => 'Extract all security, privacy, data residency, GDPR, DPA/AVV, certification, encryption, access control, audit, deletion, retention, insurance, and SLA requirements.',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Compliance', 'sort' => 130, 'required' => true, 'threshold' => 80,
        'hint' => 'For German and EU buyers, capture GDPR/AVV language exactly where possible.'
    },
    new Map<String, Object>{
        'name' => 'Commercial and Licensing Requirements',
        'text' => 'What budget, pricing, licensing, user-count, contract-term, service-level, implementation-effort, or cost-model requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Commercial', 'sort' => 140, 'required' => false, 'threshold' => 65,
        'hint' => 'Include agent counts, concurrent users, full/light users, modules, and growth assumptions.'
    },
    new Map<String, Object>{
        'name' => 'Evaluation Criteria and Response Instructions',
        'text' => 'What evaluation criteria, scoring weights, mandatory response format, demo expectations, required attachments, vendor questions, and submission delivery instructions are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Submission', 'sort' => 150, 'required' => true, 'threshold' => 80,
        'hint' => 'Capture instructions that directly affect proposal compliance.'
    },
    new Map<String, Object>{
        'name' => 'Salesforce Fit Summary',
        'text' => 'Using the RFP document and the Salesforce grounding context, summarize where the opportunity aligns with Salesforce Service Cloud, Agentforce, Data Cloud, MuleSoft, Tableau, Slack, partner delivery, and trust capabilities. Also name the most important mismatches or unknowns.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Strategy', 'sort' => 210, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Recommended Win Themes',
        'text' => 'What 3-5 win themes should Salesforce emphasize in the response? Tie each theme to a specific RFP requirement and to a Salesforce capability, customer-proof category, trust proof point, or implementation approach from the grounding context.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Strategy', 'sort' => 220, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Risks Gaps and Partner Needs',
        'text' => 'Identify the highest-priority pursuit risks for Salesforce. Consider native-versus-partner capability gaps, telephony/contact-center architecture, workforce management, data migration, GDPR/AVV, German localization, timeline, licensing complexity, and mandatory requirements. State how each risk should be mitigated.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Risk', 'sort' => 230, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Proof Points and References',
        'text' => 'Which Salesforce public proof points, customer-story types, trust/privacy materials, product pages, or partner credentials would be most relevant for this RFP? Explain why each proof point category matters for the buyer.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Evidence', 'sort' => 240, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Clarification Questions',
        'text' => 'List the clarification questions Salesforce should ask the issuer before finalizing the proposal. Prioritize questions that affect scope, architecture, licensing, implementation effort, data migration, integrations, telephony, workforce management, compliance, and evaluation scoring.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Pursuit', 'sort' => 250, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Go No-Go Recommendation',
        'text' => 'Give a clear Go, No-Go, or Conditional Go recommendation for Salesforce. Weigh product fit, strategic value, proof strength, delivery feasibility, risk, competitive posture, and commercial complexity. If Conditional Go, state the conditions that must be met.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Pursuit', 'sort' => 260, 'required' => false, 'threshold' => 0
    }
};

List<Extraction_Question__c> questions = new List<Extraction_Question__c>();
for (Map<String, Object> row : rows) {
    Extraction_Question__c question = new Extraction_Question__c(
        Name = (String) row.get('name'),
        Extraction_Profile__c = profile.Id,
        Question_Text__c = (String) row.get('text'),
        Question_Type__c = (String) row.get('type'),
        Output_Type__c = (String) row.get('output'),
        Category__c = (String) row.get('category'),
        Sort_Order__c = (Integer) row.get('sort'),
        Is_Active__c = true,
        Is_Required__c = (Boolean) row.get('required'),
        Confidence_Threshold__c = (Integer) row.get('threshold')
    );
    if (row.containsKey('hint')) {
        question.Extraction_Hint__c = (String) row.get('hint');
    }
    questions.add(question);
}

insert questions;

System.debug('Seeded profile ' + profile.Id + ' with ' + questions.size() + ' questions.');
