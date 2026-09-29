# IT Operations Runbook — AnyCompany Manufacturing Systems

## Document Information

- **Runbook ID**: ACM-ITOPS-RB-003
- **Version**: 4.2
- **Last Updated**: March 2025
- **Owner**: IT Operations Center, AnyCompany Americas
- **On-Call Rotation**: Follow PagerDuty schedule "ACM-ITOPS-Primary"

## Overview

This runbook provides standard operating procedures for the IT Operations team responsible for maintaining AnyCompany's manufacturing execution systems (MES), enterprise resource planning (ERP) integrations, and supporting infrastructure. The runbook covers common incident scenarios, escalation procedures, and routine maintenance tasks specific to AnyCompany's tire manufacturing environment.

All procedures assume the operator has VPN access to the AnyCompany corporate network and appropriate IAM credentials for the referenced systems. Production changes require Change Advisory Board (CAB) approval unless classified as emergency changes under the incident management process.

## System Inventory

### Critical Manufacturing Systems

| System | Purpose | SLA | RPO/RTO |
|---|---|---|---|
| SAP S/4HANA | ERP - Production Planning | 99.9% | 1hr / 4hr |
| Siemens MES | Manufacturing Execution | 99.95% | 15min / 1hr |
| OSIsoft PI | Process Data Historian | 99.9% | 5min / 2hr |
| Wonderware InTouch | SCADA/HMI | 99.95% | N/A / 30min |
| AnyCompany Tirematics | Fleet TPMS Platform | 99.5% | 1hr / 4hr |
| AWS AI Gateway | AI/ML Service Access | 99.0% | N/A / 2hr |

### Supporting Infrastructure

| Component | Technology | Location |
|---|---|---|
| Primary Database | Oracle RAC 19c | Nashville DC |
| Disaster Recovery | Oracle Data Guard | Akron DC |
| Message Queue | IBM MQ 9.3 | Nashville DC |
| API Gateway | AWS API Gateway | us-east-1 |
| Monitoring | Datadog + CloudWatch | SaaS + us-east-1 |
| Secrets Management | HashiCorp Vault | Nashville DC |

## Procedure 1: MES Communication Failure

### Symptoms
- Production line operators report "Communication Error" on HMI screens
- Siemens MES dashboard shows disconnected PLCs
- OSIsoft PI stops receiving real-time data from affected lines

### Diagnosis Steps

1. **Check network connectivity to PLC subnet**
   ```bash
   ping -c 5 10.50.{line_number}.1
   traceroute 10.50.{line_number}.1
   ```
   Expected: All packets returned, no hops timing out

2. **Verify MES application server health**
   ```bash
   ssh mes-app-01.anycompany.internal
   systemctl status siemens-mes
   journalctl -u siemens-mes --since "30 minutes ago" | grep -i error
   ```

3. **Check OPC-UA connection status**
   ```bash
   curl -s http://mes-app-01:4840/status | jq '.connections'
   ```
   Expected: All PLC connections showing "Connected" state

4. **Review firewall rules** (if network is reachable but OPC-UA fails)
   ```bash
   ssh fw-mfg-01.anycompany.internal
   show access-list | grep "10.50.{line_number}"
   ```

### Resolution Steps

**Scenario A: Network switch failure**
1. Contact Network Operations Center (NOC) at ext. 4500
2. Identify affected switch from network topology diagram (SharePoint > IT Ops > Network Maps)
3. If redundant path available, verify failover occurred
4. If no redundancy, escalate to on-site technician for hardware replacement
5. Estimated resolution: 30-60 minutes with spare hardware

**Scenario B: MES application crash**
1. Restart the MES service:
   ```bash
   sudo systemctl restart siemens-mes
   ```
2. Wait 90 seconds for PLC reconnection
3. Verify data flow resumed in OSIsoft PI
4. If service fails to start, check disk space: `df -h /opt/siemens`
5. If disk full, archive old logs: `./scripts/archive-mes-logs.sh --days 30`

**Scenario C: OPC-UA certificate expiration**
1. Check certificate expiry: `openssl x509 -in /opt/siemens/certs/opcua.pem -noout -enddate`
2. If expired, generate new certificate using internal CA
3. Deploy certificate and restart OPC-UA server
4. Re-establish trust with all PLC endpoints

### Escalation

- **15 minutes**: If diagnosis incomplete, page secondary on-call
- **30 minutes**: If production line stopped, notify Plant Manager and escalate to P1
- **60 minutes**: If multiple lines affected, activate Major Incident process

## Procedure 2: SAP Integration Queue Backup

### Symptoms
- IBM MQ queue depth exceeding 10,000 messages
- SAP IDocs showing "Error" status in SM58 transaction
- Production orders not flowing from SAP to MES

### Diagnosis Steps

1. **Check MQ queue depth**
   ```bash
   echo "DISPLAY QLOCAL(SAP.TO.MES.*) CURDEPTH" | runmqsc BSTPROD01
   ```

2. **Verify MQ channel status**
   ```bash
   echo "DISPLAY CHSTATUS(SAP.SENDER) ALL" | runmqsc BSTPROD01
   ```
   Expected: STATUS(RUNNING)

3. **Check SAP RFC connection**
   - Log into SAP GUI → Transaction SM59
   - Test connection to MES RFC destination
   - Check for timeout or authentication errors

4. **Review dead letter queue**
   ```bash
   echo "DISPLAY QLOCAL(SYSTEM.DEAD.LETTER.QUEUE) CURDEPTH" | runmqsc BSTPROD01
   ```

### Resolution Steps

1. If channel stopped, restart:
   ```bash
   echo "START CHANNEL(SAP.SENDER)" | runmqsc BSTPROD01
   ```

2. If messages are poison (repeatedly failing):
   ```bash
   # Move poison messages to holding queue for analysis
   ./scripts/move-poison-msgs.sh --source SAP.TO.MES.PROD --target SAP.TO.MES.HOLD --count 100
   ```

3. If SAP RFC credentials expired:
   - Retrieve new credentials from Vault: `vault read secret/sap/rfc-user`
   - Update SM59 destination in SAP
   - Test connection

4. After resolution, verify queue is draining:
   ```bash
   watch -n 5 'echo "DISPLAY QLOCAL(SAP.TO.MES.PROD) CURDEPTH" | runmqsc BSTPROD01'
   ```

## Procedure 3: AWS AI Gateway Health Check

### Symptoms
- AI-powered quality inspection returning errors
- Tirematics predictive models not updating
- CloudWatch alarms firing for API Gateway 5XX errors

### Diagnosis Steps

1. **Check API Gateway health**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/ApiGateway \
     --metric-name 5XXError \
     --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Sum
   ```

2. **Check Lambda function errors**
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/lambda/search-kb \
     --start-time $(date -d '30 minutes ago' +%s000) \
     --filter-pattern "ERROR"
   ```

3. **Verify Bedrock model availability**
   ```bash
   aws bedrock get-foundation-model \
     --model-identifier us.anthropic.claude-sonnet-4-6 \
     --query 'modelDetails.modelLifecycle.status'
   ```

4. **Check rate limiting status**
   ```bash
   aws apigateway get-usage \
     --usage-plan-id $(aws apigateway get-usage-plans --query 'items[?name==`IT-Operations-Plan`].id' --output text) \
     --key-id $(aws apigateway get-api-keys --query 'items[?name==`IT-Operations-key`].id' --output text) \
     --start-date $(date +%Y-%m-%d) \
     --end-date $(date +%Y-%m-%d)
   ```

### Resolution Steps

1. If rate limited, request quota increase or wait for reset
2. If Lambda timeout, check Bedrock service health dashboard
3. If authentication errors, verify Cognito token validity
4. If persistent 5XX, check Lambda memory/timeout configuration

## Routine Maintenance Tasks

### Daily
- Review overnight alert summary in PagerDuty
- Check MQ queue depths (threshold: 5,000 warning, 10,000 critical)
- Verify backup completion for Oracle databases
- Review AI Gateway CloudWatch dashboard for anomalies

### Weekly
- Rotate application log files on MES servers
- Review and close resolved incidents in ServiceNow
- Update capacity planning spreadsheet with current utilization
- Test disaster recovery failover for one non-critical system

### Monthly
- Apply security patches to non-production environments
- Review and update this runbook with lessons learned
- Conduct tabletop exercise for one disaster recovery scenario
- Audit IAM access and remove stale credentials

### Quarterly
- Full disaster recovery test (production failover)
- Capacity planning review with infrastructure team
- Security vulnerability scan of all manufacturing network segments
- Review and update escalation contact lists

## Contact Directory

| Role | Name | Phone | Escalation Level |
|---|---|---|---|
| IT Ops Primary On-Call | PagerDuty Rotation | Auto-page | L1 |
| IT Ops Manager | See PagerDuty | ext. 4501 | L2 |
| Network Operations | NOC Team | ext. 4500 | L1 (network) |
| SAP Basis Admin | SAP Team | ext. 4520 | L2 (SAP) |
| Plant IT Manager | Site-specific | See directory | L3 |
| VP IT Operations | Executive | ext. 4001 | L4 (Major Incident) |

## Related Documents

- Incident Management Process: ACM-ITOPS-IMP-001
- Change Management Policy: ACM-ITOPS-CMP-002
- Disaster Recovery Plan: ACM-ITOPS-DRP-001
- Network Architecture Diagram: SharePoint > IT Ops > Network Maps
- Internal Ticket Category: IT-Operations > Runbook > [System Name]
