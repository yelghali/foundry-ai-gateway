---
doc_id: spec-fpx2000
title: FPX-2000 5-Axis CNC Milling Center — Technical Specification
domain: product-specs
product: FPX-2000
revision: C
effective: 2025-11-01
---

# FPX-2000 5-Axis CNC Milling Center — Technical Specification

## Overview
The Fabrikam FPX-2000 is a 5-axis simultaneous CNC milling center designed for
aerospace and medical-grade machining of titanium, Inconel, and aluminum alloys.
It pairs a 24,000 RPM HSK-A63 spindle with a trunnion-style rotary table for
full 5-axis contouring.

## Mechanical specifications
| Parameter | Value |
| --- | --- |
| X / Y / Z travel | 800 / 600 / 550 mm |
| A-axis rotation | -120° to +120° |
| C-axis rotation | 360° continuous |
| Table diameter | 500 mm |
| Max workpiece weight | 300 kg |
| Positioning accuracy | ±0.004 mm |
| Repeatability | ±0.002 mm |

## Spindle
- Power: 22 kW (S1 continuous), 30 kW (S6 40%)
- Max torque: 119 Nm
- Taper: HSK-A63
- Through-spindle coolant: 70 bar standard, 150 bar optional

## Control system
The FPX-2000 ships with the Fabrikam OpenControl 7 CNC, based on a real-time
Linux kernel. It supports G-code, conversational programming, and a REST API for
MES integration. Tool life management and in-process probing (Renishaw OMP60) are
standard.

## Power and utilities
- Electrical: 400 V, 3-phase, 50/60 Hz, 45 kVA
- Compressed air: 6 bar, 200 L/min
- Coolant tank: 320 L

## Environmental
Operating temperature 5–40 °C, relative humidity 30–95% non-condensing. For
positioning accuracy specifications to hold, ambient temperature must be held to
±2 °C. See maintenance SOP MNT-COOL-12 for chiller calibration.
