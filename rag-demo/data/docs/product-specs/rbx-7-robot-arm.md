---
doc_id: spec-rbx7
title: RBX-7 6-Axis Industrial Robot Arm — Specification
domain: product-specs
product: RBX-7
revision: A
effective: 2026-02-01
---

# RBX-7 6-Axis Industrial Robot Arm — Specification

## Overview
The RBX-7 is a 6-axis articulated robot for material handling, welding, and
machine tending. It is rated IP67 at the wrist and IP54 at the base, suitable for
foundry and machining environments.

## Key specifications
| Parameter | Value |
| --- | --- |
| Payload | 7 kg |
| Reach | 911 mm |
| Repeatability | ±0.02 mm |
| Axes | 6 |
| Weight | 34 kg |
| Mounting | floor, ceiling, wall, angle |

## Motion range
| Axis | Range | Max speed |
| --- | --- | --- |
| J1 | ±170° | 360°/s |
| J2 | -90° to +135° | 300°/s |
| J3 | -80° to +160° | 360°/s |
| J4 | ±190° | 450°/s |
| J5 | ±120° | 450°/s |
| J6 | ±360° | 720°/s |

## Controller and safety
The RBX-7 uses the Fabrikam RC-7 controller with dual-channel Cat. 3 PL d safety
I/O. Safe-torque-off (STO), safe-limited-speed (SLS), and collaborative
speed-and-separation monitoring are supported when paired with a certified area
scanner. See safety document SDS-ROB-03 for collaborative operation limits.

## Electrical and interfaces
- Supply: 200–240 V single-phase, 2.0 kVA
- Digital I/O: 16 in / 16 out, expandable
- Fieldbus: PROFINET, EtherNet/IP, Modbus TCP
- Programming: teach pendant, Fabrikam Studio offline programming, Python SDK

## Maintenance interval
Grease J2/J3 reducers every 12 months or 6,000 hours; see SOP MNT-ROB-30.
