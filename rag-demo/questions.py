"""
Evaluation question set for the MAF-vs-Foundry-IQ comparison.

Mix of single-domain lookups and cross-domain questions whose answers are split across
two or three indexes (these are where an agentic/multi-query planner should beat a single
top-k search). `expects` lists doc_ids that a good answer should draw on — used by
04_compare.py to score grounding/recall.
"""

QUESTIONS = [
    {
        "id": "q1-single-spec",
        "text": "What is the positioning accuracy and spindle taper of the FPX-2000?",
        "expects": ["spec-fpx2000"],
        "note": "Single-domain factual lookup (product-specs).",
    },
    {
        "id": "q2-cross-cnc-thermal",
        "text": (
            "Our FPX-2000 is drifting out of tolerance. What accuracy is it rated for, "
            "and what maintenance and ambient conditions keep it in spec?"
        ),
        "expects": ["spec-fpx2000", "mnt-cool-12"],
        "note": "Cross-domain: spec accuracy + chiller calibration + ambient requirement.",
    },
    {
        "id": "q3-cross-pump-fluid",
        "text": (
            "We want to convert an HPX-450 pump from mineral oil to water-glycol fluid. "
            "What pressure is it rated for, what must we do to the pump, and what safety "
            "steps apply to the fluid change?"
        ),
        "expects": ["spec-hpx450", "mnt-pump-21", "sds-hyd-07"],
        "note": "Three-index synthesis: spec + maintenance + safety datasheet.",
    },
    {
        "id": "q4-cross-robot-collab",
        "text": (
            "Can the RBX-7 run collaboratively next to an operator? What payload and speed "
            "limits apply, and what maintenance keeps its repeatability and safety valid?"
        ),
        "expects": ["spec-rbx7", "sds-rob-03", "mnt-rob-30"],
        "note": "Three-index synthesis: spec + collaborative safety + reducer greasing.",
    },
    {
        "id": "q5-cross-loto",
        "text": (
            "Before servicing the FPX-2000 spindle chiller, what lockout and coolant-handling "
            "safety steps are required, and what is the calibration acceptance criterion?"
        ),
        "expects": ["sds-cool-09", "mnt-cool-12"],
        "note": "Cross-domain: safety LOTO + maintenance acceptance criteria.",
    },
    {
        "id": "q6-figure-pump-efficiency",
        "text": (
            "On the HPX-450 bench performance curve, at what flow rate does volumetric "
            "efficiency peak, what is that peak efficiency, and what is the recommended "
            "operating flow band?"
        ),
        "expects": ["spec-hpx450"],
        "note": "Figure-only: answer lives solely in the embedded PQ curve image (88% @ 24 L/min, band 15–28 L/min).",
    },
    {
        "id": "q7-figure-robot-zones",
        "text": (
            "What are the radii of the RBX-7 protective and warning safety zones, and which "
            "safety reaction (STO or SLS) is triggered in each?"
        ),
        "expects": ["sds-rob-03"],
        "note": "Figure-only: zone radii (0.90 m protective→STO, 1.60 m warning→SLS) are in the plan-view image, not the prose.",
    },
]
