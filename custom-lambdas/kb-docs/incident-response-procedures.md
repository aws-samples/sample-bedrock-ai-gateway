# Incident Response Procedures — AnyCompany IT & OT Security

## Document Information

- **Document ID**: ACM-IR-PROC-001
- **Version**: 5.0
- **Last Updated**: January 2025
- **Owner**: Chief Information Security Officer (CISO), AnyCompany Americas
- **Classification**: Confidential — Internal Use Only
- **Review Cycle**: Semi-annual

## Purpose

This document defines the incident response procedures for AnyCompany Corporation's IT and Operational Technology (OT) environments. These procedures ensure a coordinated, efficient, and effective response to cybersecurity incidents, system outages, data breaches, and operational disruptions that could impact manufacturing operations, corporate systems, or customer data.

All AnyCompany employees, contractors, and managed service providers are required to follow these procedures when responding to or reporting security incidents. Failure to follow established procedures may result in disciplinary action and increased organizational risk.

## Incident Classification

### Severity Levels

**SEV-1 (Critical)**
- Active data breach involving customer PII or financial data
- Ransomware infection spreading across network segments
- Manufacturing line shutdown due to cyber attack
- Complete loss of critical business system (SAP, MES)
- Safety system compromise (TPMS, vehicle dynamics)
- **Response Time**: Immediate (within 15 minutes)
- **Notification**: CISO, CIO, Legal, affected business unit VP
- **Bridge Call**: Continuous until resolved

**SEV-2 (High)**
- Confirmed unauthorized access to internal systems
- Malware detected on multiple endpoints
- Partial system outage affecting business operations
- Suspected data exfiltration (under investigation)
- OT network anomaly detected by Claroty/Darktrace
- **Response Time**: Within 30 minutes
- **Notification**: CISO, IT Security Manager, affected system owners
- **Bridge Call**: Established within 1 hour

**SEV-3 (Medium)**
- Single endpoint malware infection (contained)
- Phishing campaign targeting AnyCompany employees
- Unauthorized access attempt (blocked by controls)
- Non-critical system outage
- Policy violation detected (data handling, access control)
- **Response Time**: Within 2 hours
- **Notification**: IT Security team, affected user's manager
- **Bridge Call**: As needed

**SEV-4 (Low)**
- Suspicious email reported (not yet confirmed malicious)
- Minor policy violation (password sharing, tailgating)
- Vulnerability scan finding requiring patching
- False positive alert requiring tuning
- **Response Time**: Within 24 hours (next business day)
- **Notification**: IT Security analyst on duty

## Incident Response Phases

### Phase 1: Detection and Identification

**Detection Sources**:
- SIEM alerts (Splunk) — automated correlation rules
- EDR alerts (CrowdStrike Falcon) — endpoint behavioral detection
- Network IDS/IPS (Palo Alto, Claroty) — network-based detection
- User reports — phishing emails, suspicious activity
- Cloud security alerts (AWS GuardDuty, CloudTrail anomalies)
- Vulnerability scanner findings (Qualys, Tenable)
- Third-party threat intelligence feeds
- AI Gateway anomaly detection (unusual API patterns, token usage spikes)

**Initial Triage Checklist**:
1. Confirm the alert is not a false positive (check multiple data sources)
2. Determine scope: How many systems/users are affected?
3. Identify the attack vector: email, web, network, physical, insider
4. Classify severity using the matrix above
5. Document initial findings in the incident ticket (ServiceNow)
6. Assign incident commander based on severity and type

**Incident Ticket Creation**:
- Create ticket in ServiceNow under category: Security > Incident Response
- Required fields: Title, Severity, Affected Systems, Detection Source, Initial Assessment
- Assign to: Security Operations Center (SOC) queue
- Tag with relevant MITRE ATT&CK techniques if identifiable

### Phase 2: Containment

**Immediate Containment (Short-term)**:

The goal is to stop the incident from spreading while preserving evidence for investigation.

- **Endpoint Isolation**: Use CrowdStrike to network-isolate affected endpoints (maintains management connectivity for investigation)
- **Account Lockout**: Disable compromised user accounts in Active Directory and Cognito
- **Network Segmentation**: Apply emergency firewall rules to block lateral movement
  ```bash
  # Emergency block rule template (Palo Alto)
  set rulebase security rules EMERGENCY-BLOCK-{ticket_id} \
    from any to any source {compromised_ip} \
    action deny log-start yes
  ```
- **API Key Revocation**: If AI Gateway credentials compromised, immediately revoke API keys:
  ```bash
  aws apigateway update-api-key --api-key {key_id} --patch-operations op=replace,path=/enabled,value=false
  ```
- **DNS Sinkhole**: Redirect known C2 domains to internal sinkhole server

**System-Specific Containment**:

| System | Containment Action |
|---|---|
| Manufacturing (OT) | Isolate affected line at Zone 2 firewall; do NOT power off PLCs |
| SAP S/4HANA | Lock affected user IDs; enable enhanced audit logging |
| AWS AI Gateway | Disable affected usage plan; rotate Cognito user pool tokens |
| Email (O365) | Block sender domain; quarantine delivered messages |
| VPN | Revoke affected user certificates; force re-authentication |

**Evidence Preservation**:
- Do NOT reboot or power off affected systems (destroys volatile memory evidence)
- Capture memory dump before any remediation: `winpmem_mini_x64.exe memdump.raw`
- Preserve relevant log files (copy, do not move)
- Document all containment actions with timestamps in the incident ticket
- Enable enhanced logging on adjacent systems

### Phase 3: Eradication

**Malware Removal**:
1. Identify all affected systems using IOCs (indicators of compromise)
2. Deploy CrowdStrike custom IOC rules to detect and block malware variants
3. Remove malware artifacts from affected endpoints
4. Verify removal with full system scan
5. Check for persistence mechanisms (scheduled tasks, registry keys, startup items, cron jobs)

**Vulnerability Remediation**:
1. Identify the exploited vulnerability
2. Apply patches or configuration changes to close the attack vector
3. Verify fix effectiveness with targeted vulnerability scan
4. Apply same fix to all potentially vulnerable systems (not just compromised ones)

**Credential Reset**:
1. Force password reset for all potentially compromised accounts
2. Revoke and reissue API keys, tokens, and certificates
3. Rotate service account credentials
4. Update secrets in HashiCorp Vault
5. For AI Gateway: regenerate Cognito app client secrets, invalidate all active sessions

### Phase 4: Recovery

**System Restoration Priority**:
1. Safety-critical systems (TPMS, manufacturing safety interlocks)
2. Manufacturing execution (MES, SCADA)
3. Enterprise applications (SAP, email)
4. Supporting services (AI Gateway, analytics)
5. Non-critical systems (development, testing)

**Recovery Steps**:
1. Restore systems from known-good backups (verify backup integrity first)
2. Rebuild compromised systems from golden images where possible
3. Gradually reconnect isolated systems to the network
4. Monitor restored systems intensively for 72 hours post-recovery
5. Verify business processes are functioning correctly
6. Confirm data integrity (compare checksums, transaction counts)

**Validation Checklist**:
- [ ] All malware artifacts confirmed removed
- [ ] Exploited vulnerability patched across environment
- [ ] Compromised credentials rotated
- [ ] Affected systems restored and functional
- [ ] Enhanced monitoring in place for 30 days
- [ ] No signs of persistent attacker access
- [ ] Business operations confirmed normal

### Phase 5: Post-Incident Activities

**Post-Incident Review (PIR)**:
- Schedule within 5 business days of incident closure
- Required attendees: Incident Commander, SOC analysts, affected system owners, IT management
- Agenda:
  1. Timeline reconstruction (what happened, when)
  2. What worked well in the response
  3. What could be improved
  4. Root cause analysis (5 Whys methodology)
  5. Action items with owners and deadlines

**Documentation Requirements**:
- Complete incident timeline with all actions taken
- Root cause analysis report
- Impact assessment (systems affected, data exposed, business disruption duration)
- Lessons learned document
- Updated runbooks if procedures were inadequate
- Regulatory notification assessment (GDPR 72-hour requirement, state breach notification laws)

**Metrics Tracking**:
- Mean Time to Detect (MTTD)
- Mean Time to Contain (MTTC)
- Mean Time to Recover (MTTR)
- Number of systems affected
- Data records potentially exposed
- Business downtime (hours)
- Financial impact estimate

## Communication Protocols

### Internal Communication

- **Incident Bridge**: Microsoft Teams channel "Security-Incident-{ticket_id}"
- **Status Updates**: Every 30 minutes for SEV-1, every 2 hours for SEV-2
- **Executive Briefing**: Written summary for SEV-1/SEV-2 within 4 hours
- **All-Hands Communication**: Only with CISO and Legal approval

### External Communication

- **Law Enforcement**: FBI IC3 for cyber crimes; coordinate through Legal
- **Regulators**: GDPR supervisory authority (72 hours), state AG offices (per state law)
- **Customers**: Only with Legal and Communications team approval
- **Insurance**: Notify cyber insurance carrier within 24 hours for SEV-1/SEV-2
- **Third-Party IR**: Engage CrowdStrike Services for SEV-1 if internal capacity exceeded

### Communication Templates

Templates for all standard communications are maintained in SharePoint:
- IT Ops > Security > Incident Response > Communication Templates
- Includes: executive briefing, employee notification, customer notification, regulatory filing

## Special Procedures: OT/Manufacturing Incidents

Manufacturing environments require special handling due to safety implications:

1. **Never remotely shut down manufacturing equipment** without Plant Manager approval
2. **Prioritize human safety** over system preservation in all decisions
3. **Coordinate with plant operations** before any network changes affecting OT zones
4. **Engage Claroty support** for OT-specific malware analysis
5. **Document physical safety checks** performed during and after incident
6. **Regulatory reporting**: CISA ICS-CERT notification for confirmed OT cyber incidents

## Tools and Resources

| Tool | Purpose | Access |
|---|---|---|
| Splunk Enterprise | SIEM, log analysis | siem.anycompany.internal |
| CrowdStrike Falcon | EDR, threat hunting | falcon.crowdstrike.com |
| Palo Alto Cortex XSOAR | SOAR, playbook automation | xsoar.anycompany.internal |
| Claroty | OT network monitoring | claroty.anycompany.internal |
| ServiceNow | Incident ticketing | snow.anycompany.internal |
| HashiCorp Vault | Secrets management | vault.anycompany.internal |
| Qualys | Vulnerability management | qualys.anycompany.internal |

## Training and Exercises

- **Tabletop Exercises**: Quarterly, rotating scenarios (ransomware, data breach, OT attack, insider threat)
- **Purple Team Exercises**: Semi-annual, coordinated attack simulation with red team
- **Phishing Simulations**: Monthly, all employees
- **IR Team Training**: Annual SANS certification maintenance (GCIH, GCIA)
- **New Hire Training**: Security awareness within first week, IR procedures within first month

## Contact Information

- **Security Operations Center (SOC)**: soc@anycompany.com, ext. 4600 (24/7)
- **CISO Office**: ciso-office@anycompany.com
- **Legal (Privacy)**: privacy-legal@anycompany.com
- **Communications**: corp-comms@anycompany.com
- **CrowdStrike IR Hotline**: 1-855-CROWD-IR (escalation only)
- **Internal Ticket Category**: Security > Incident-Response > [Severity Level]
