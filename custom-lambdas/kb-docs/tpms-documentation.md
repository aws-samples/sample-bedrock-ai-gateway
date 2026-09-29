# Tire Pressure Monitoring System (TPMS) — Technical Documentation

## Overview

The Tire Pressure Monitoring System (TPMS) is a safety technology integrated into vehicles manufactured after 2007 (required by US Federal Motor Vehicle Safety Standard 138). TPMS continuously monitors air pressure inside pneumatic tires and alerts the driver when pressure falls below the recommended threshold.

## System Types

### Direct TPMS
- Each tire contains a battery-powered pressure sensor transmitting via 315 MHz or 433 MHz RF
- Provides real-time individual tire pressure readings
- Sensor battery life: 5–10 years depending on usage
- Sensors must be relearned after tire rotation or replacement

### Indirect TPMS
- Uses wheel speed sensors from the Anti-lock Braking System (ABS)
- Detects pressure loss by comparing wheel rotation speeds (underinflated tires rotate faster)
- No battery to replace, but requires system reset after inflation adjustments

## Alert Thresholds

| Alert Type | Threshold | Dashboard Indicator |
|---|---|---|
| Low pressure warning | > 25% below recommended PSI | Amber TPMS light |
| Critical low pressure | > 40% below recommended PSI | Flashing TPMS light + audible alert |
| Sensor malfunction | No signal for > 15 minutes | Amber TPMS light with fault code |
| High pressure | > 110% of recommended PSI | Amber TPMS light |

## Recommended Pressure Values

Refer to the vehicle's door jamb sticker or owner's manual. Standard passenger vehicle ranges:

| Vehicle Type | Front (PSI) | Rear (PSI) |
|---|---|---|
| Passenger car | 32–35 | 32–35 |
| Light truck/SUV | 35–45 | 35–45 |
| Heavy commercial | 90–120 | 90–120 |

> Always check pressure when tires are cold (driven less than 1 mile). Pressure increases 4–6 PSI when hot.

## Sensor Replacement Procedure

1. Remove tire from rim
2. Remove old sensor using sensor removal tool
3. Install new sensor with fresh valve stem seal and grommet
4. Torque sensor nut to 35–62 in-lb (per manufacturer spec)
5. Remount tire; inflate to recommended pressure
6. Perform sensor relearn procedure using TPMS tool

## Common Diagnostic Codes

| Code | Description | Resolution |
|---|---|---|
| C0750 | Tire pressure sensor fault (FL) | Replace sensor, relearn |
| C0755 | Tire pressure sensor fault (FR) | Replace sensor, relearn |
| C0760 | Tire pressure sensor fault (RL) | Replace sensor, relearn |
| C0765 | Tire pressure sensor fault (RR) | Replace sensor, relearn |
| C0775 | Low sensor battery | Replace sensor |
| B2AAE | System voltage low | Check vehicle charging system |

## Fleet Management Integration

For fleet applications, TPMS data can be streamed to a central fleet management platform:

- Sensors transmit data to an in-vehicle telematics gateway
- Gateway forwards readings via cellular to fleet management API
- Fleet portal displays real-time tire health across all vehicles
- Automated work orders generated when pressure falls below threshold
- Historical pressure data retained for 90 days for trend analysis

## Maintenance Schedule

| Interval | Task |
|---|---|
| Monthly | Visual inspection of all tires; manual pressure check |
| Quarterly | TPMS system test; verify all sensor signals present |
| Annually | Full sensor battery status check; replace sensors > 7 years old |
| At tire change | Relearn all sensors; replace valve stems |

## Support

For TPMS diagnostic equipment or sensor sourcing, contact your fleet maintenance supplier or the vehicle manufacturer's technical support line.
