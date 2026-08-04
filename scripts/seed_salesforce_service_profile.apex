// Seeds (or refreshes) the "Salesforce Service RFP" Extraction Profile.
// Assumption: the sender archetype is enterprise and midmarket customer-service
// organizations modernizing service, contact center, reporting, knowledge, and AI workflows.
// Idempotent: re-running deletes the profile's existing questions and reinserts them.

String PROFILE_NAME = 'Salesforce Service RFP';

String groundingContext = '';
groundingContext = groundingContext + 'Evaluator company: Salesforce\n';
groundingContext = groundingContext + 'Purpose of this profile: Help Salesforce evaluate incoming RFPs from enterprise and midmarket customer-service organizations modernizing service, contact center, knowledge, reporting, workflow, integration, and AI-assisted support. This profile assumes the sender is a service buyer, not a one-off niche procurement.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'Company snapshot:\n';
groundingContext = groundingContext + '- Salesforce is a global CRM and customer engagement vendor.\n';
groundingContext = groundingContext + '- Service Cloud / Agentforce Service is the Salesforce customer service platform for cases, knowledge, incidents, omnichannel service, automation, and AI.\n';
groundingContext = groundingContext + '- Salesforce also offers Data Cloud, MuleSoft, Tableau, Slack, and Agentforce capabilities that commonly appear in service-platform deals.\n';
groundingContext = groundingContext + '- Salesforce operates globally and maintains extensive public trust, privacy, compliance, and documentation resources.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'Relevant offerings and capabilities:\n';
groundingContext = groundingContext + '- Service Cloud / Agentforce Service can support case management, a unified agent workspace, knowledge, self-service, service automation, omnichannel routing, and service analytics.\n';
groundingContext = groundingContext + '- Agentforce capabilities are relevant where the buyer wants agent assist, response generation, summarization, and workflow automation.\n';
groundingContext = groundingContext + '- MuleSoft and Salesforce APIs are relevant when buyers require integration with ERP, order, identity, telephony, contact center, or legacy systems.\n';
groundingContext = groundingContext + '- Data Cloud and Tableau are relevant when buyers need a unified customer context and reporting.\n';
groundingContext = groundingContext + '- Salesforce has a broad partner ecosystem for implementation, migration, localization, and change management.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'Customer and market evidence:\n';
groundingContext = groundingContext + '- Public Salesforce customer stories span enterprise and midmarket buyers in retail, healthcare, education, media, and professional services.\n';
groundingContext = groundingContext + '- Examples include LY Corporation, Adecco Group, MIMIT Health, Pandora, and Pearson, which show broad demand for service, AI, and workflow modernization.\n';
groundingContext = groundingContext + '- Public trust materials include privacy statements, a Data Processing Addendum, Data Transfer Mechanisms FAQ, Data Privacy Framework certification, EU/UK Binding Corporate Rules, and transparency reports.\n';
groundingContext = groundingContext + '- Use only public and relevant proof points in response recommendations.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'Likely strengths in RFP responses:\n';
groundingContext = groundingContext + '- Strong fit when the RFP asks for a unified agent desktop, CRM-connected customer history, omnichannel support, workflow automation, knowledge management, AI assistance, and reporting.\n';
groundingContext = groundingContext + '- Strong fit when the buyer values security and privacy documentation, enterprise scalability, and a phased implementation model with partners.\n';
groundingContext = groundingContext + '- Strong fit when the opportunity requires integration across multiple systems and channels.\n';
groundingContext = groundingContext + '- Strong fit when the buyer wants measurable service outcomes rather than only point features.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'Known gaps, caveats, or assumptions:\n';
groundingContext = groundingContext + '- This profile assumes a customer-service or contact-center modernization deal rather than a narrow one-off feature request.\n';
groundingContext = groundingContext + '- Native telephony, workforce management, and some channel-specific capabilities may require Salesforce add-ons, AppExchange partners, or implementation scoping.\n';
groundingContext = groundingContext + '- Exact pricing, licensing mix, data residency, German-language delivery, and detailed GDPR or AVV commitments must be validated against the actual RFP and commercial architecture.\n';
groundingContext = groundingContext + '- If the sender is not a service buyer, the profile should be reworked around the product line being evaluated.\n';
groundingContext = groundingContext + '\n';
groundingContext = groundingContext + 'How to use this context:\n';
groundingContext = groundingContext + '- Use it for fit, risk, win themes, proof-point selection, and response strategy.\n';
groundingContext = groundingContext + '- Do not treat this context as content from the RFP document.';

Extraction_Profile__c profile;
List<Extraction_Profile__c> existing = [
    SELECT Id FROM Extraction_Profile__c WHERE Name = :PROFILE_NAME LIMIT 1
];

if (existing.isEmpty()) {
    profile = new Extraction_Profile__c(Name = PROFILE_NAME);
} else {
    profile = existing[0];
}

profile.Description__c = 'Reusable Salesforce service-platform RFP profile for enterprise and midmarket customer-service modernization opportunities.';
profile.Grounding_Context__c = groundingContext;
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
        'name' => 'Project Title',
        'text' => 'What is the official title or name of the project, program, or solicitation being requested?',
        'type' => 'Extraction', 'output' => 'Text', 'category' => 'Overview', 'sort' => 10, 'required' => true, 'threshold' => 80,
        'hint' => 'Return the exact title from the cover page or solicitation header.'
    },
    new Map<String, Object>{
        'name' => 'Issuing Organization',
        'text' => 'What is the name of the organization, agency, or company issuing this RFP?',
        'type' => 'Extraction', 'output' => 'Text', 'category' => 'Overview', 'sort' => 20, 'required' => true, 'threshold' => 80,
        'hint' => 'Return the legal entity name, not a department name.'
    },
    new Map<String, Object>{
        'name' => 'Submission Deadline',
        'text' => 'What is the deadline for submitting proposals in response to this RFP? Return a single date if one is stated.',
        'type' => 'Extraction', 'output' => 'Date', 'category' => 'Timeline', 'sort' => 30, 'required' => true, 'threshold' => 80,
        'hint' => 'Return the latest hard cutoff date if multiple deadlines are listed.'
    },
    new Map<String, Object>{
        'name' => 'Q&A or Intent-to-Bid Deadline',
        'text' => 'What is the deadline for submitting questions, notice of intent to bid, or intent-to-respond for this RFP?',
        'type' => 'Extraction', 'output' => 'Date', 'category' => 'Timeline', 'sort' => 35, 'required' => false, 'threshold' => 75,
        'hint' => 'Return the question or intent-to-bid date if one is stated.'
    },
    new Map<String, Object>{
        'name' => 'Primary Contact',
        'text' => 'Who are the points of contact for questions and submissions? Return all contacts listed, including name, title, and email where available.',
        'type' => 'Extraction', 'output' => 'Text', 'category' => 'Contacts', 'sort' => 40, 'required' => true, 'threshold' => 80,
        'hint' => 'Include all named contacts, one per line if possible.'
    },
    new Map<String, Object>{
        'name' => 'Required Capabilities',
        'text' => 'List the core capabilities, services, or product categories the responding vendor must provide.',
        'type' => 'Extraction', 'output' => 'List', 'category' => 'Scope', 'sort' => 50, 'required' => true, 'threshold' => 75,
        'hint' => 'Return a concise list and prefer the wording used in the document.'
    },
    new Map<String, Object>{
        'name' => 'Current Systems and Replacement Scope',
        'text' => 'What current systems, tools, channels, spreadsheets, or manual processes does the RFP say should be replaced, integrated, migrated, or retained?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Current State', 'sort' => 60, 'required' => false, 'threshold' => 75,
        'hint' => 'Capture what should be replaced, kept, or integrated.'
    },
    new Map<String, Object>{
        'name' => 'Required Integrations with Existing Systems',
        'text' => 'What existing systems, platforms, channels, or data sources must the solution integrate with?',
        'type' => 'Extraction', 'output' => 'List', 'category' => 'Architecture', 'sort' => 70, 'required' => false, 'threshold' => 75,
        'hint' => 'List named systems, channels, or data sources.'
    },
    new Map<String, Object>{
        'name' => 'Reporting and Analytics Requirements',
        'text' => 'What reporting, dashboard, KPI, analytics, supervisor, manager, or service-performance requirements are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Reporting', 'sort' => 80, 'required' => false, 'threshold' => 70,
        'hint' => 'Capture dashboards, KPIs, audiences, and any required reporting frequency.'
    },
    new Map<String, Object>{
        'name' => 'Security, Privacy, and Compliance Requirements',
        'text' => 'Extract all security, privacy, data residency, GDPR, DPA/AVV, certification, encryption, access control, audit, retention, insurance, and SLA requirements.',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Compliance', 'sort' => 90, 'required' => false, 'threshold' => 80,
        'hint' => 'Capture compliance language exactly where possible.'
    },
    new Map<String, Object>{
        'name' => 'Implementation Timeline and Milestones',
        'text' => 'What implementation timeline, go-live date, pilot, migration, training, or rollout milestones are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Timeline', 'sort' => 100, 'required' => false, 'threshold' => 70,
        'hint' => 'Capture phase dates and major milestones, not just the final deadline.'
    },
    new Map<String, Object>{
        'name' => 'Submission Format and Delivery Instructions',
        'text' => 'What response format, portal, email, file type, page limit, naming, attachment, or delivery instructions are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Submission', 'sort' => 110, 'required' => false, 'threshold' => 80,
        'hint' => 'Capture any compliance instructions that affect how the proposal must be submitted.'
    },
    new Map<String, Object>{
        'name' => 'Evaluation Criteria and Scoring Weights',
        'text' => 'What evaluation criteria, mandatory requirements, scoring weights, demo expectations, or vendor-selection instructions are stated?',
        'type' => 'Extraction', 'output' => 'Long Text', 'category' => 'Submission', 'sort' => 120, 'required' => false, 'threshold' => 80,
        'hint' => 'Capture scoring details and mandatory requirements that influence proposal compliance.'
    },
    new Map<String, Object>{
        'name' => 'Estimated Contract Value',
        'text' => 'What is the estimated total contract value, budget ceiling, or expected spend for this engagement?',
        'type' => 'Extraction', 'output' => 'Currency', 'category' => 'Commercial', 'sort' => 130, 'required' => false, 'threshold' => 60,
        'hint' => 'If a range is given, return the upper bound. If no amount is stated, leave blank and lower confidence.'
    },
    new Map<String, Object>{
        'name' => 'Salesforce Fit Summary',
        'text' => 'Using the RFP document and the Salesforce grounding context, summarize where the opportunity aligns with or conflicts with Salesforce Service Cloud / Agentforce Service, Data Cloud, MuleSoft, Tableau, Slack, partner delivery, and trust capabilities. Note the most important unknowns.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Strategy', 'sort' => 210, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Recommended Win Themes',
        'text' => 'What 3-5 win themes should Salesforce emphasize in the response? Tie each theme to a specific RFP requirement and a Salesforce capability, public proof point category, or implementation approach from the grounding context.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Strategy', 'sort' => 220, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Risks, Gaps, and Clarification Questions',
        'text' => 'Identify the highest-priority pursuit risks for Salesforce. Consider partner dependencies, telephony or contact-center architecture, workforce management, data migration, security and privacy, localization, timeline, licensing complexity, and any mandatory requirements. Include the key clarification questions we should ask the issuer.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Pursuit', 'sort' => 230, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Public Proof Points and References',
        'text' => 'Which Salesforce public customer stories, industries, trust materials, product pages, or partner credentials are most relevant for this RFP, and why?' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Evidence', 'sort' => 240, 'required' => false, 'threshold' => 0
    },
    new Map<String, Object>{
        'name' => 'Go / No-Go Recommendation',
        'text' => 'Should Salesforce pursue this RFP? Give a clear Go, No-Go, or Conditional Go recommendation, then explain the reasoning by weighing fit, win probability, effort, strategic value, and risk. If Conditional, name the conditions.' + wordCap,
        'type' => 'Reasoning', 'output' => 'Long Text', 'category' => 'Pursuit', 'sort' => 250, 'required' => false, 'threshold' => 0
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
