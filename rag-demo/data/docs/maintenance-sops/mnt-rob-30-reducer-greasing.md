---
doc_id: mnt-rob-30
title: MNT-ROB-30 — RBX-7 Reducer Greasing and Backlash Check
domain: maintenance-sops
product: RBX-7
revision: A
effective: 2026-02-20
---

# MNT-ROB-30 — RBX-7 Reducer Greasing and Backlash Check

## Interval
Every 12 months or 6,000 operating hours, whichever comes first. High-duty
foundry installations should halve the interval to 6 months / 3,000 hours.

## Grease specification
Use only Fabrikam GR-9 (lithium-complex, NLGI 2) for J1–J3 reducers and GR-4
(synthetic, NLGI 1) for J4–J6. Mixing grease types voids the drivetrain warranty.
Refer to SDS-GR-11 for grease handling and disposal.

## Greasing procedure
1. Move the robot to the maintenance pose `MNT-POSE-1` via the teach pendant.
2. Engage safe-torque-off (STO) and lock out the controller.
3. Remove the grease inlet and outlet plugs for the target axis.
4. Inject GR-9 with a manual grease gun until fresh grease appears at the outlet.
   - J2 reducer capacity: 95 g
   - J3 reducer capacity: 70 g
5. Re-install the outlet plug, run axis jog for 2 minutes to distribute grease,
   then re-install the inlet plug.
6. Wipe excess grease and reset the maintenance counter in **Service > Counters**.

## Backlash check
1. Mount a dial indicator on the J2 output flange.
2. Apply ±5 Nm of manual torque and read total backlash.
3. Acceptable: ≤ 1.0 arc-min. Above 2.0 arc-min indicates reducer wear; schedule
   replacement.

## Notes
Do not over-grease: excess grease raises reducer temperature and can blow the
shaft seals. If repeatability has drifted beyond ±0.02 mm after greasing, run the
RBX-7 mastering routine before returning the robot to production.
