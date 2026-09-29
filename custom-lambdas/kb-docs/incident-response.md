# Incident Response Procedures — AnyCompany Americas IT

## Document Information

| Field | Value |
|-------|-------|
| Document ID | IR-PROC-2024-005 |
| Version | 3.4 |
| Last Updated | 2024-10-30 |
| Owner | IT Service Management Office |
| Classification | Internal — IT Staff Only |
| Compliance | ISO 27001:2022, NIST CSF 2.0, SOC 2 Type II |

## 1. Purpose and Scope

This document defines the incident response procedures for all IT-related incidents affecting AnyCompany Americas operations. It establishes a consistent, repeatable process for detecting, responding to, resolving, and learning from incidents to minimize business impact and prevent recurrence.

These procedures apply to all technology incidents including but not limited to: application failures, infrastructure outages, security breaches, data loss events, network disruptions, manufacturing system failures, and third-party service degradations that impact AnyCompany business operations.

All IT staff, contractors, and managed service providers supporting AnyCompany systems are required to follow these procedures. Failure to adhere to these procedures may result in delayed resolution, increased business impact, and potential disciplinary action.

## 2. Severity Classification

### 2.1 Priority Definitions

Incidents are classified using a priority matrix that considers both business impact and urgency:

**P1 — Critical (Business Stopping)**

A P1 incident represents a complete loss of a critical business function with no workaround available, affecting manufacturing production, revenue generation, or employee safety. Examples include:

- Manufacturing Execution System (MES) failure causing production line stoppage at any plant
- SAP S/4HANA production instance completely unavailable
- Complete network outage at a manufacturing facility or distribution center
- Security breach with confirmed data exfiltration in progress
- Safety system failure (fire suppression, environmental monitoring, access control)
- Payment processing system failure affecting all retail locations
- Complete loss of warehouse management system during peak shipping hours

P1 incidents require immediate mobilization of the incident response team regardless of time of day. The Incident Commander role is automatically activated, and executive notification occurs within 30 minutes.

**P2 — High (Major Degradation)**

A P2 incident represents significant degradation of a critical business function or complete loss of a non-critical function affecting a large user population (100+ users). A workaround may exist but is not sustainable. Examples include:

- SAP performance degraded by more than 50%, causing transaction timeouts
- Email system (Microsoft 365) unavailable for an entire region
- VPN infrastructure failure preventing remote work for 500+ employees
- Partial MES failure affecting quality data collection but not stopping production
- Customer-facing website or portal unavailable
- Single plant network degradation causing intermittent SCADA communication failures
- Bedrock AI Gateway returning errors for more than 25% of requests

P2 incidents require response within 30 minutes and resolution within 4 hours. The on-call manager is notified immediately, and a bridge call is established within 15 minutes of declaration.

**P3 — Medium (Limited Impact)**

A P3 incident affects a limited number of users (10-100) or a non-critical business function with an acceptable workaround available. Examples include:

- Single application experiencing intermittent errors for a department
- Printer fleet failure at one location
- VPN connectivity issues for a specific site
- Non-production environment outage affecting development teams
- Individual server failure with automatic failover (monitoring alert, no user impact)
- AI Gateway rate limiting triggering for a single API key (by design, but user reports confusion)
- Knowledge base search returning incomplete results

P3 incidents are handled during business hours with resolution targeted within 24 business hours.

**P4 — Low (Minimal Impact)**

A P4 incident has minimal business impact, affects fewer than 10 users, or represents a cosmetic issue with a readily available workaround. Examples include:

- Individual user unable to access a non-critical application
- Minor UI display issues in internal tools
- Documentation errors or outdated information
- Feature requests misclassified as incidents
- Informational alerts that do not indicate actual service degradation

P4 incidents are addressed within 5 business days and may be converted to service requests or problem tickets as appropriate.

### 2.2 Priority Assignment Matrix

| | High Urgency | Medium Urgency | Low Urgency |
|---|---|---|---|
| **High Impact** (>1000 users or critical system) | P1 | P2 | P3 |
| **Medium Impact** (100-1000 users or important system) | P2 | P3 | P3 |
| **Low Impact** (<100 users or non-critical system) | P3 | P3 | P4 |

## 3. Response Times and SLAs

### 3.1 Response Time Requirements

| Priority | Acknowledge | First Update | Resolution Target | Escalation Trigger |
|----------|-------------|--------------|-------------------|--------------------|
| P1 | 5 minutes | 15 minutes | 4 hours | 30 min without progress |
| P2 | 15 minutes | 30 minutes | 8 hours | 2 hours without progress |
| P3 | 1 hour | 4 hours | 24 business hours | 8 hours without progress |
| P4 | 4 business hours | Next business day | 5 business days | 3 days without progress |

### 3.2 Escalation Paths

**Technical Escalation (resolver capability):**

```
L1: ITOC Analyst → L2: Application/Infrastructure SME → L3: Engineering Lead → L4: Vendor/Architect
```

**Management Escalation (authority/resources):**

```
On-Call Analyst → On-Call Manager → IT Director → VP of IT → CIO
```

**Executive Escalation (P1 only):**

```
CIO → COO → CEO (for incidents with external customer or regulatory impact)
```

### 3.3 Escalation Triggers

Escalation is mandatory when:
- Resolution time exceeds 50% of the SLA without a clear path to resolution
- The incident scope expands (more systems, more users, more locations)
- The incident has confirmed security implications (data breach, unauthorized access)
- External parties are affected (customers, partners, regulators)
- The resolver requires access, authority, or resources beyond their level
- Business leadership requests escalation regardless of technical progress

## 4. Communication Templates

### 4.1 Initial Notification (P1/P2)

**Subject**: [P{X}] {System Name} — {Brief Description} — INC{number}

**Body**:
```
INCIDENT NOTIFICATION

Priority: P{X}
Incident ID: INC{number}
Time Detected: {YYYY-MM-DD HH:MM} ET
Affected System: {system name}
Impact: {description of business impact}
Affected Users/Sites: {scope}
Current Status: Investigating / Identified / Mitigating

Bridge Call: {dial-in number} / {Teams link}
Incident Commander: {name}
Next Update: {time} ET

Actions Taken:
- {action 1}
- {action 2}

Please do NOT reply-all to this notification. Direct questions to the bridge call.
```

### 4.2 Status Update Template

**Subject**: [UPDATE {N}] [P{X}] {System Name} — {Brief Description} — INC{number}

**Body**:
```
INCIDENT STATUS UPDATE #{N}

Priority: P{X}
Incident ID: INC{number}
Duration: {hours}h {minutes}m
Current Status: {Investigating / Identified / Mitigating / Resolved}

Summary of Progress:
- {what has been done since last update}
- {what was found}

Current Theory/Root Cause:
- {working hypothesis or confirmed root cause}

Next Steps:
- {planned action 1} — ETA: {time}
- {planned action 2} — ETA: {time}

Estimated Resolution: {time} ET (or "Under investigation")
Next Update: {time} ET

Bridge Call: {dial-in number} / {Teams link}
Incident Commander: {name}
```

### 4.3 Resolution Notification

**Subject**: [RESOLVED] [P{X}] {System Name} — {Brief Description} — INC{number}

**Body**:
```
INCIDENT RESOLVED

Priority: P{X}
Incident ID: INC{number}
Duration: {total duration}
Resolution Time: {YYYY-MM-DD HH:MM} ET

Root Cause: {brief root cause description}

Resolution: {what was done to fix it}

Preventive Actions:
- {action to prevent recurrence — owner — due date}

Post-Mortem: Scheduled for {date} (P1/P2 only)

Service has been restored and verified. Please report any ongoing issues to the IT Service Desk.
```

### 4.4 Executive Summary (P1 only)

Sent to CIO and affected business unit VPs within 2 hours of P1 declaration:

```
EXECUTIVE INCIDENT SUMMARY

Incident: INC{number} — {one-line description}
Business Impact: {revenue impact, production impact, customer impact}
Duration So Far: {hours}
Estimated Resolution: {time or "under investigation"}
Incident Commander: {name, title}
Resources Engaged: {number of people, teams involved}
External Impact: {yes/no — if yes, describe}
Regulatory Notification Required: {yes/no}
Next Executive Update: {time}
```

## 5. Post-Mortem Process

### 5.1 When Post-Mortems Are Required

Post-mortem reviews are mandatory for:
- All P1 incidents
- All P2 incidents with duration exceeding 4 hours
- Any incident involving data loss or security breach
- Any incident requiring emergency change
- Incidents specifically requested by management for review
- Recurring incidents (3+ occurrences of same root cause within 90 days)

### 5.2 Post-Mortem Timeline

| Milestone | Deadline | Owner |
|-----------|----------|-------|
| Post-mortem meeting scheduled | Within 3 business days of resolution | Incident Commander |
| Draft post-mortem document | Within 5 business days of resolution | Incident Commander |
| Post-mortem meeting held | Within 7 business days of resolution | All involved parties |
| Final post-mortem published | Within 10 business days of resolution | Incident Commander |
| Action items assigned and tracked | Within 10 business days | Problem Manager |
| Action items completed | Per individual due dates (max 30 days) | Assigned owners |

### 5.3 Post-Mortem Document Structure

Every post-mortem document must include:

1. **Incident Summary**: One-paragraph description of what happened, when, and the business impact
2. **Timeline**: Minute-by-minute chronology from detection through resolution
3. **Root Cause Analysis**: Using the "5 Whys" technique or fishbone diagram to identify the true root cause (not just the proximate cause)
4. **Contributing Factors**: Environmental, process, or human factors that enabled or worsened the incident
5. **What Went Well**: Aspects of the response that worked effectively (celebrate successes)
6. **What Could Be Improved**: Gaps in detection, response, communication, or tooling
7. **Action Items**: Specific, measurable, assigned, and time-bound corrective actions
8. **Lessons Learned**: Key takeaways for the broader organization

### 5.4 Blameless Culture

AnyCompany IT follows a blameless post-mortem culture. The purpose of post-mortems is to improve systems and processes, not to assign blame to individuals. Key principles:

- Focus on systemic failures, not individual mistakes
- Assume good intent — people made the best decisions they could with available information
- Ask "what allowed this to happen?" not "who caused this?"
- Identify process gaps that permitted human error to cause system failure
- Recognize that complex systems fail in complex ways — single root causes are rare
- Psychological safety is essential — people must feel safe reporting errors and near-misses

## 6. Root Cause Analysis Methodology

### 6.1 The 5 Whys Technique

For each incident, ask "why" iteratively until the systemic root cause is identified:

**Example:**
- Why did the API Gateway return 500 errors? → The Lambda function timed out
- Why did the Lambda function time out? → The database query took longer than the 30-second timeout
- Why did the database query take so long? → A missing index caused a full table scan on a 50M row table
- Why was the index missing? → The schema migration script failed silently during last deployment
- Why did the migration fail silently? → The deployment pipeline does not verify migration success before proceeding

**Root Cause**: Deployment pipeline lacks migration verification step
**Action Item**: Add post-migration validation check to CI/CD pipeline

### 6.2 Contributing Factor Categories

When analyzing incidents, consider factors in these categories:

- **Technology**: Hardware failure, software bugs, capacity limits, configuration errors
- **Process**: Missing procedures, unclear ownership, inadequate change management
- **People**: Training gaps, fatigue, communication failures, staffing shortages
- **Environment**: Network conditions, third-party dependencies, seasonal load patterns
- **Monitoring**: Detection gaps, alert fatigue, insufficient observability

## 7. Incident Metrics and Reporting

### 7.1 Key Performance Indicators

| Metric | Target | Measurement |
|--------|--------|-------------|
| Mean Time to Detect (MTTD) | <5 minutes (P1), <15 minutes (P2) | Time from incident start to detection |
| Mean Time to Acknowledge (MTTA) | <5 minutes (P1), <15 minutes (P2) | Time from alert to human acknowledgment |
| Mean Time to Resolve (MTTR) | <4 hours (P1), <8 hours (P2) | Time from detection to confirmed resolution |
| SLA Compliance | >95% for all priorities | Percentage of incidents resolved within SLA |
| Recurring Incident Rate | <10% | Percentage of incidents with same root cause as prior incident |
| Post-Mortem Completion Rate | 100% for P1/P2 | Percentage of required post-mortems completed on time |
| Action Item Closure Rate | >90% within 30 days | Percentage of post-mortem actions completed by due date |

### 7.2 Reporting Cadence

- **Daily**: P1/P2 incident status report to IT leadership (automated from ServiceNow)
- **Weekly**: Incident summary dashboard reviewed at ITOC team meeting
- **Monthly**: Incident trend analysis presented to IT Directors (volume, MTTR, SLA compliance)
- **Quarterly**: Comprehensive incident review presented to CIO including year-over-year trends
- **Annually**: Incident management maturity assessment and process improvement plan

## 8. Tools and Access

### 8.1 Incident Management Tooling

| Tool | Purpose | Access |
|------|---------|--------|
| ServiceNow ITSM | Incident ticket management, workflow automation | All IT staff |
| PagerDuty | On-call alerting, escalation automation | On-call engineers |
| Microsoft Teams | Bridge calls, incident channels, collaboration | All IT staff |
| Datadog | Infrastructure monitoring, APM, log analysis | Operations and Engineering |
| Splunk | Security event analysis, log correlation | Operations, Security, Engineering |
| Confluence | Post-mortem documentation, knowledge base | All IT staff |
| StatusPage | Internal service status communication | ITOC (publish), All employees (view) |

### 8.2 Incident Bridge Call Procedures

For P1 and P2 incidents, a bridge call is established within 15 minutes:

1. ITOC analyst creates a dedicated Teams channel: `INC{number}-{brief-description}`
2. Starts a Teams meeting in the channel and posts the join link in the initial notification
3. Incident Commander joins and takes control of the bridge
4. All participants must identify themselves and their role when joining
5. The bridge remains open until the incident is resolved or downgraded
6. A scribe is designated to capture key decisions and actions in the channel chat
7. Non-essential participants should leave the bridge and monitor the channel for updates

## 9. Continuous Improvement

The incident management process is reviewed and improved through:

- Monthly process retrospectives with the ITOC team
- Quarterly tabletop exercises simulating P1 scenarios
- Annual disaster recovery exercises testing end-to-end response capabilities
- Benchmarking against industry standards (ITIL 4, SRE practices)
- Feedback surveys sent to incident participants after each P1/P2 resolution
- Regular training and certification for incident management roles (ITIL, PagerDuty certifications)

All improvement initiatives are tracked in the IT Service Improvement Plan and reported to the IT Governance Board quarterly.
