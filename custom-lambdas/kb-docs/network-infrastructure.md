# Network Infrastructure Guide — AnyCompany Americas

## Document Information

| Field | Value |
|-------|-------|
| Document ID | NET-INFRA-2024-012 |
| Version | 5.1 |
| Last Updated | 2024-11-01 |
| Owner | Network Engineering Team |
| Classification | Internal — IT Staff Only |

## 1. Overview

This document describes the network infrastructure architecture supporting AnyCompany Americas operations across 50+ manufacturing plants, 2,200+ retail locations (Firestone Complete Auto Care), 4 regional distribution centers, and corporate offices in Nashville, TN (Americas headquarters), Akron, OH (technical center), and São Paulo, Brazil (BSLA headquarters).

The network infrastructure is designed to support mission-critical manufacturing operations with sub-millisecond latency requirements for SCADA/PLC communications, high-bandwidth data transfers for quality inspection imaging systems, and reliable connectivity for enterprise applications including SAP S/4HANA, Microsoft 365, and cloud-based AI/ML workloads on AWS.

Total network footprint: approximately 85,000 connected endpoints, 12,000 network devices, and 450 Gbps aggregate WAN bandwidth across all facilities.

## 2. Data Center Connectivity

### 2.1 Primary Data Centers

| Data Center | Location | Role | Connectivity |
|-------------|----------|------|-------------|
| NSH-DC1 | Nashville, TN | Primary enterprise DC | 2x 100Gbps to AWS Direct Connect, 4x 40Gbps WAN uplinks |
| NSH-DC2 | Nashville, TN (15 miles from DC1) | DR/secondary enterprise DC | 2x 100Gbps to DC1, 2x 100Gbps to AWS Direct Connect |
| AKR-DC1 | Akron, OH | Technical center / R&D compute | 2x 40Gbps to NSH-DC1, 1x 100Gbps to AWS Direct Connect |
| SAO-DC1 | São Paulo, Brazil | BSLA regional DC | 2x 10Gbps to NSH-DC1, 1x 10Gbps local internet breakout |

### 2.2 AWS Cloud Connectivity

AnyCompany Americas maintains AWS Direct Connect connections for hybrid cloud workloads:

**Direct Connect Configuration:**
- NSH-DC1: 2x 100Gbps dedicated connections to AWS us-east-1 (N. Virginia)
- NSH-DC2: 2x 100Gbps dedicated connections to AWS us-east-1 (redundant path)
- AKR-DC1: 1x 100Gbps dedicated connection to AWS us-east-2 (Ohio)
- Virtual Interfaces: 15 private VIFs across 8 AWS accounts, 3 public VIFs for S3/DynamoDB
- BGP configuration: AS 65001 (AnyCompany private ASN), multi-hop eBGP with AWS AS 7224

**Transit Gateway Architecture:**
- Regional Transit Gateways in us-east-1 and us-east-2
- Inter-region peering between Transit Gateways for cross-region workloads
- Route tables segmented by environment: Production, Non-Production, Shared Services, DMZ
- Attachment limit monitoring: alert at 80% of 5,000 attachment limit per TGW

**VPC Design Standards:**
- CIDR allocation from 10.128.0.0/10 (enterprise cloud range, non-overlapping with on-premises 10.0.0.0/10)
- Minimum /22 per VPC for growth capacity
- Subnet strategy: 3 AZs, public/private/data tiers per AZ
- VPC Flow Logs enabled on all production VPCs (sent to central Splunk)
- DNS resolution via Route 53 Resolver with forwarding rules to on-premises Active Directory

### 2.3 Manufacturing Plant Connectivity

Each manufacturing plant connects to the enterprise network via:

**Primary WAN Link:**
- MPLS circuit: 1 Gbps (small plants) to 10 Gbps (large plants like Wilson, NC and Warren County, TN)
- Provider: AT&T AVPN (primary), Lumen (secondary where available)
- SLA: 99.99% availability, <50ms latency to Nashville DC, <0.1% packet loss

**Secondary WAN Link:**
- SD-WAN overlay on broadband internet: 500 Mbps - 2 Gbps
- Provider: Local ISP (varies by location)
- Used for: non-critical traffic (internet, Microsoft 365, guest WiFi), failover for MPLS

**Local Network:**
- Plant floor: Industrial Ethernet (Cisco IE switches, ruggedized for manufacturing environment)
- Office areas: Cisco Catalyst 9000 series switches
- Wireless: Cisco 9800 controllers with Wi-Fi 6E access points (office), Cisco Industrial Wireless (plant floor)
- Segmentation: VLANs separating OT (Operational Technology), IT, Guest, and IoT networks

### 2.4 Retail Location Connectivity

Firestone Complete Auto Care locations use a standardized connectivity stack:

- Primary: SD-WAN appliance (Cisco Viptela) on business-class broadband (100-500 Mbps)
- Backup: 4G/LTE cellular failover (Cradlepoint)
- Local switching: Cisco Meraki MS switches (cloud-managed)
- Wireless: Cisco Meraki MR access points (separate SSIDs for POS, back-office, customer WiFi)
- Security: Meraki MX firewall with content filtering and IPS

## 3. VPN Configurations

### 3.1 Remote Access VPN

**Solution**: Cisco AnyConnect Secure Mobility Client with Cisco ASA/FTD headends

**Configuration:**
- Authentication: SAML integration with Azure Entra ID (MFA required)
- Split tunneling: Enabled for Microsoft 365 and approved SaaS applications
- Full tunnel: Required for access to manufacturing systems, SAP, and internal applications
- Concurrent user capacity: 15,000 sessions across 4 VPN concentrators (geo-distributed)
- Client versions supported: AnyConnect 4.10+ (Windows, macOS, iOS, Android, Linux)

**VPN Profiles:**
| Profile | Access Level | Split Tunnel | Idle Timeout |
|---------|-------------|--------------|--------------|
| Corporate-Standard | Internal apps, file shares, intranet | Yes (M365 excluded) | 8 hours |
| Corporate-FullTunnel | All traffic through corporate network | No | 4 hours |
| Manufacturing-Remote | Plant floor systems, SCADA HMI | No | 2 hours |
| Vendor-Limited | Specific systems per vendor agreement | No | 1 hour |
| Emergency-Admin | Full infrastructure access | No | 30 minutes |

### 3.2 Site-to-Site VPN

**Inter-site backup tunnels:**
- Technology: IPsec IKEv2 with AES-256-GCM encryption
- Routing: BGP over IPsec for dynamic failover
- Keepalive: DPD (Dead Peer Detection) every 10 seconds
- Used as backup path when MPLS circuit fails

**Third-party vendor tunnels:**
- Dedicated IPsec tunnels to key partners (tire mold suppliers, logistics providers, SAP hosting)
- Each tunnel restricted to specific source/destination IP ranges
- Monitored for availability and throughput via PRTG
- Annual security review of all vendor tunnel configurations

### 3.3 AWS VPN Connections

- Site-to-Site VPN as backup to Direct Connect (2 tunnels per connection for redundancy)
- BGP-based routing with lower preference than Direct Connect paths
- Automatic failover: Direct Connect failure triggers VPN path activation within 60 seconds
- Client VPN endpoints in AWS for developer access to cloud workloads (separate from corporate VPN)

## 4. Firewall Rules and Security Zones

### 4.1 Security Zone Architecture

The network is segmented into the following security zones:

```
┌─────────────────────────────────────────────────────────┐
│                    INTERNET (Untrusted)                   │
├─────────────────────────────────────────────────────────┤
│                    DMZ (Semi-Trusted)                     │
│  Web servers, reverse proxies, email gateways, WAF       │
├─────────────────────────────────────────────────────────┤
│                 CORPORATE (Trusted)                       │
│  End-user devices, printers, collaboration tools         │
├─────────────────────────────────────────────────────────┤
│              SERVER / DATA CENTER (Restricted)            │
│  Application servers, databases, file servers            │
├─────────────────────────────────────────────────────────┤
│           MANUFACTURING / OT (Highly Restricted)         │
│  PLCs, SCADA, HMI, quality inspection systems           │
├─────────────────────────────────────────────────────────┤
│              MANAGEMENT (Administrative)                  │
│  Network devices, hypervisors, backup systems            │
└─────────────────────────────────────────────────────────┘
```

### 4.2 Inter-Zone Traffic Rules (Summary)

| Source Zone | Destination Zone | Default Policy | Exceptions |
|-------------|-----------------|----------------|------------|
| Internet → DMZ | Allow (specific ports) | HTTP/443, SMTP/25 | WAF inspection required |
| DMZ → Server | Allow (specific apps) | App-specific ports only | No direct DB access |
| Corporate → Server | Allow (authenticated) | Standard app ports | MFA for admin access |
| Corporate → OT | Deny | — | Approved jump hosts only |
| OT → Server | Allow (specific) | MES data upload ports | Unidirectional preferred |
| OT → Internet | Deny | — | Vendor remote access via jump host |
| Any → Management | Deny | — | NOC workstations, approved admins |

### 4.3 Firewall Platforms

- **Perimeter**: Palo Alto PA-5400 series (NSH-DC1, NSH-DC2), PA-3400 (regional DCs)
- **Internal segmentation**: Palo Alto PA-800 series at plant boundaries
- **Cloud**: AWS Network Firewall (centralized inspection VPC), Palo Alto VM-Series in select accounts
- **Retail**: Cisco Meraki MX (integrated firewall/SD-WAN)
- **Management**: Panorama for centralized policy management across all Palo Alto devices

### 4.4 Firewall Change Process

All firewall rule changes must follow the change management process:
1. Request submitted via ServiceNow with business justification
2. Security team reviews for compliance with zone policies and least-privilege principle
3. Network team implements in test environment (Panorama device group: Pre-Production)
4. Validation testing confirms connectivity without unintended access
5. Production deployment during approved maintenance window
6. Post-implementation verification within 24 hours
7. Rule review: all rules audited quarterly, unused rules (zero hit count for 90 days) flagged for removal

## 5. Bandwidth Management

### 5.1 QoS Policy

Traffic is classified and prioritized using DSCP markings:

| Traffic Class | DSCP | Priority | Bandwidth Guarantee | Examples |
|--------------|------|----------|--------------------|---------| 
| Voice/Video | EF (46) | Highest | 20% | Teams calls, video conferencing |
| Manufacturing Critical | AF41 (34) | High | 30% | SCADA, PLC, MES communications |
| Business Critical | AF31 (26) | Medium-High | 25% | SAP, WMS, email |
| Standard Data | AF21 (18) | Medium | 15% | File transfers, web browsing |
| Best Effort | BE (0) | Low | 10% | Software updates, backups, guest WiFi |

### 5.2 Bandwidth Monitoring

- Real-time utilization dashboards in PRTG (per-link, per-site)
- Alert threshold: 80% sustained utilization for 15+ minutes
- Capacity planning: quarterly review of utilization trends, upgrade when average exceeds 60%
- NetFlow/IPFIX collection for traffic analysis and anomaly detection

## 6. Disaster Recovery — Network

### 6.1 DR Scenarios and Recovery Targets

| Scenario | RTO | RPO | Recovery Procedure |
|----------|-----|-----|-------------------|
| Single WAN link failure | 0 (automatic failover) | 0 | SD-WAN/MPLS redundancy handles automatically |
| Data center network failure | 15 minutes | 0 | Traffic reroutes via secondary DC, DNS failover |
| Regional ISP outage | 30 minutes | 0 | 4G/LTE failover at affected sites, traffic rerouting |
| Complete site loss (disaster) | 4 hours | 1 hour | DR site activation, DNS updates, VPN re-termination |
| AWS region failure | 1 hour | 15 minutes | Multi-region architecture, Route 53 health checks trigger failover |

### 6.2 DR Testing Schedule

- **Monthly**: Automated failover testing of redundant WAN links (non-disruptive)
- **Quarterly**: Simulated data center network failure with manual failover procedures
- **Annually**: Full DR exercise including site evacuation scenario and DR site activation
- **Ad-hoc**: Post-incident testing when a real failover reveals gaps in procedures

### 6.3 Network Configuration Backup

- All network device configurations backed up daily to central repository (Oxidized)
- Configuration change detection alerts sent to Network Operations team
- Backup retention: 90 days of daily backups, 12 months of weekly backups
- DR site maintains synchronized configuration for all critical network devices
- Restoration tested monthly: random device selected, configuration restored to lab equipment

## 7. Contact Information

| Role | Contact | Availability |
|------|---------|-------------|
| Network Operations Center | noc@anycompany.com / ext. 5555 | 24/7 |
| Network Engineering (Escalation) | net-eng@anycompany.com | Business hours + on-call |
| Security Operations Center | soc@anycompany.com / ext. 5911 | 24/7 |
| Cloud Engineering | cloud-team@anycompany.com | Business hours + on-call |
| Vendor Support (AT&T AVPN) | 1-800-ATT-BSAM (dedicated line) | 24/7 |
| Vendor Support (Palo Alto) | TAC Case via support portal | 24/7 for P1 |
