# Network Infrastructure Guide — AnyCompany Manufacturing & Corporate

## Document Information

- **Document ID**: ACM-NET-INFRA-001
- **Version**: 3.4
- **Last Updated**: February 2025
- **Owner**: Network Engineering, AnyCompany Americas
- **Classification**: Internal Use Only

## Overview

This guide documents the network infrastructure architecture supporting AnyCompany's manufacturing plants, corporate offices, and cloud environments across the Americas region. The network is designed to support operational technology (OT) systems in manufacturing, information technology (IT) corporate systems, and hybrid cloud connectivity to AWS for AI/ML workloads and enterprise applications.

The network architecture follows a defense-in-depth security model with strict segmentation between IT and OT environments, aligned with the Purdue Enterprise Reference Architecture (PERA) model and IEC 62443 industrial cybersecurity standards.

## Network Architecture

### Zones and Segmentation

The network is divided into the following security zones, each with distinct access controls and monitoring requirements:

**Zone 0-1: Process Control Network (PCN)**
- PLCs, sensors, actuators, and HMI panels
- Flat Layer 2 network per production line
- No direct internet connectivity
- Subnet: 10.50.0.0/16 (per plant)
- Protocols: EtherNet/IP, PROFINET, Modbus TCP, OPC-UA
- Firewall: Palo Alto PA-5260 (OT-specific rules)

**Zone 2: Manufacturing DMZ**
- MES servers, historians (OSIsoft PI), SCADA servers
- Bridges OT and IT networks with strict access controls
- Subnet: 10.60.0.0/16 (per plant)
- Only approved protocols traverse this boundary (OPC-UA, SQL, HTTPS)
- All traffic logged and inspected by IDS/IPS

**Zone 3: IT Operations Network**
- Corporate servers, databases, application servers
- SAP S/4HANA, IBM MQ, Oracle databases
- Subnet: 10.10.0.0/16 (Nashville DC), 10.20.0.0/16 (Akron DC)
- Standard enterprise security controls (NAC, endpoint protection)

**Zone 4: Corporate User Network**
- End-user workstations, VoIP phones, printers
- Subnet: 172.16.0.0/12 (segmented by site and department)
- 802.1X authentication required for wired connections
- WPA3-Enterprise for wireless (SSID: ACM-Corporate)

**Zone 5: Cloud and Internet DMZ**
- AWS Direct Connect termination
- Internet-facing services (VPN concentrators, web proxies)
- Subnet: 192.168.0.0/16 (DMZ)
- All outbound traffic through Zscaler cloud proxy

### AWS Cloud Connectivity

AnyCompany maintains dedicated connectivity to AWS through the following architecture:

**AWS Direct Connect**
- Primary: 10 Gbps dedicated connection at Nashville DC (Equinix NA1)
- Secondary: 10 Gbps dedicated connection at Akron DC (CoreSite AK1)
- Virtual Interfaces:
  - Private VIF to production VPC (10.100.0.0/16)
  - Private VIF to development VPC (10.101.0.0/16)
  - Transit VIF to AWS Transit Gateway for multi-VPC routing
- BGP ASN: 65001 (AnyCompany) ↔ 7224 (AWS)
- Failover: Active/passive with automatic BGP failover (< 60 seconds)

**AWS VPC Architecture**
- Production VPC: 10.100.0.0/16 (us-east-1)
  - Private subnets: Lambda functions, RDS, ElastiCache
  - Public subnets: ALB, NAT Gateways
  - Isolated subnets: Bedrock VPC endpoints
- Development VPC: 10.101.0.0/16 (us-east-1)
- DR VPC: 10.102.0.0/16 (us-west-2)
- VPC Peering: Production ↔ Development (restricted routes)
- Transit Gateway: Connects all VPCs and Direct Connect

**VPC Endpoints (PrivateLink)**
- com.amazonaws.us-east-1.bedrock-runtime (AI Gateway access)
- com.amazonaws.us-east-1.s3 (Knowledge Base documents)
- com.amazonaws.us-east-1.logs (CloudWatch Logs)
- com.amazonaws.us-east-1.execute-api (API Gateway)
- com.amazonaws.us-east-1.secretsmanager (Credentials)

### DNS Architecture

- **Internal DNS**: Microsoft Active Directory DNS (anycompany.internal)
- **Cloud DNS**: Amazon Route 53 Private Hosted Zones
  - aws.anycompany.internal → resolves to VPC resources
  - Conditional forwarding from on-premises to Route 53 Resolver endpoints
- **External DNS**: Route 53 Public Hosted Zones (anycompany.com subdomains)
- **Split-horizon**: Same hostnames resolve differently internal vs. external

### Load Balancing

- **On-Premises**: F5 BIG-IP LTM (Nashville DC, Akron DC)
  - Virtual servers for SAP, MES web interfaces, internal APIs
  - Health monitoring with custom probes
  - SSL offloading with HSM-backed certificates
- **AWS**: Application Load Balancer (ALB)
  - Target groups for Lambda functions and ECS services
  - WAF integration for API protection
  - Certificate management via ACM

## Network Security Controls

### Firewall Architecture

| Location | Device | Purpose |
|---|---|---|
| Internet Edge | Palo Alto PA-7080 | Perimeter defense, IPS, URL filtering |
| OT/IT Boundary | Palo Alto PA-5260 | Industrial protocol inspection |
| DC Core | Cisco Firepower 4150 | East-west traffic inspection |
| AWS | Security Groups + NACLs | Cloud workload protection |
| Remote Access | Palo Alto GlobalProtect | VPN with posture assessment |

### Network Access Control (NAC)

- **Solution**: Cisco ISE (Identity Services Engine)
- **Wired**: 802.1X with EAP-TLS (certificate-based)
- **Wireless**: WPA3-Enterprise with RADIUS authentication
- **Guest**: Captive portal with sponsor approval workflow
- **IoT/OT Devices**: MAC Authentication Bypass (MAB) with profiling
- **Posture Assessment**: Endpoint compliance check before network access (OS patches, AV status, disk encryption)

### Network Monitoring and Detection

- **Flow Analysis**: Cisco Stealthwatch (NetFlow/IPFIX collection from all core switches)
- **IDS/IPS**: Palo Alto Threat Prevention + Claroty for OT-specific threat detection
- **SIEM Integration**: All network logs forwarded to Splunk Enterprise
- **Anomaly Detection**: Darktrace Enterprise for AI-based threat detection
- **Packet Capture**: Full packet capture at OT/IT boundary (72-hour retention)

## IP Address Management (IPAM)

### Allocation Summary

| Range | Zone | Purpose |
|---|---|---|
| 10.10.0.0/16 | IT Operations | Nashville DC servers |
| 10.20.0.0/16 | IT Operations | Akron DC servers |
| 10.50.0.0/16 | OT/PCN | Manufacturing PLCs (per plant) |
| 10.60.0.0/16 | Mfg DMZ | MES, historians |
| 10.100.0.0/16 | AWS Prod | Production VPC |
| 10.101.0.0/16 | AWS Dev | Development VPC |
| 10.102.0.0/16 | AWS DR | Disaster Recovery VPC |
| 172.16.0.0/12 | Corporate | End-user devices |
| 192.168.0.0/16 | DMZ | Internet-facing services |

### DHCP Configuration

- **Corporate**: Windows DHCP servers with 80% address pool utilization threshold alerts
- **Manufacturing**: Static IP assignment for all OT devices (managed in NetBox IPAM)
- **AWS**: VPC DHCP option sets with custom DNS and NTP servers

## Wireless Infrastructure

### Corporate Wireless
- **Controller**: Cisco 9800-CL (cloud-hosted controller)
- **Access Points**: Cisco Catalyst 9130AXI (Wi-Fi 6)
- **SSIDs**:
  - ACM-Corporate (802.1X, employee devices)
  - ACM-Guest (captive portal, internet-only)
  - ACM-IoT (WPA2-PSK, isolated VLAN for IoT devices)
- **Coverage**: All office areas, conference rooms, common spaces
- **Capacity**: Minimum 50 Mbps per user in high-density areas

### Manufacturing Wireless
- **Access Points**: Cisco Catalyst 9124AXD (industrial-rated, IP67)
- **SSIDs**:
  - ACM-MFG (WPA3, authorized maintenance tablets only)
  - ACM-AGV (WPA2, automated guided vehicles)
- **Coverage**: Production floor, warehouse, loading docks
- **Considerations**: RF interference from heavy machinery, metal structures

## Disaster Recovery Network

### Failover Scenarios

**Scenario 1: Nashville DC Failure**
- Direct Connect fails over to Akron DC secondary connection (BGP convergence < 60s)
- Oracle Data Guard activates standby database
- DNS TTL of 60 seconds enables rapid service failover
- Manufacturing plants continue operating on local MES (store-and-forward mode)

**Scenario 2: AWS Region Failure (us-east-1)**
- Route 53 health checks detect failure
- Traffic routes to us-west-2 DR VPC
- RTO: 4 hours for full service restoration
- RPO: 1 hour (cross-region replication lag)

**Scenario 3: Internet Connectivity Loss**
- Manufacturing operations unaffected (OT network is air-gapped from internet)
- Corporate users lose cloud application access
- VPN users disconnected
- Satellite backup link activates for critical communications (limited bandwidth: 50 Mbps)

## Change Management for Network

All network changes must follow the IT Change Management process:

- **Standard Changes** (pre-approved): VLAN additions, firewall rule additions for approved applications, new switch port activations
- **Normal Changes**: New network segments, routing changes, firewall policy modifications — require CAB approval
- **Emergency Changes**: Security incident response, production-impacting outages — post-implementation review required within 48 hours

## Contact Information

- **Network Operations Center (NOC)**: ext. 4500, noc@anycompany.com
- **Network Engineering**: net-eng@anycompany.com
- **Cloud Infrastructure**: cloud-team@anycompany.com
- **OT Security**: ot-security@anycompany.com
- **Internal Ticket Category**: Network > Infrastructure > [Sub-category]
