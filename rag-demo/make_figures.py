"""
Step 0b — Generate realistic engineering figures and embed them in the corpus.

Real manufacturing documents are not plain prose: datasheets carry performance
curves, safety sheets carry zone diagrams, and SOPs carry control-loop trends. This
script renders three such figures with matplotlib and drops them next to the
Markdown docs (in each domain's ``figures/`` folder). Each figure deliberately
encodes at least one quantitative fact that appears **nowhere in the document text**
— so the only way a RAG engine can answer a question about it is to actually read
the picture (image verbalization at ingest; see common.verbalize_image).

Run:
    python make_figures.py          # (re)render all figures

Figures:
    product-specs/figures/hpx450-pq-curve.png      peak vol. efficiency 88% @ 24 L/min
    safety-compliance/figures/rbx7-collab-zones.png protective 0.90 m / warning 1.60 m
    maintenance-sops/figures/cool12-chiller-trend.png  soft-alarm band 19.5-20.5 C
"""

import os

import matplotlib

matplotlib.use("Agg")  # headless, deterministic PNGs
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Circle

import config as cfg

FIG_DPI = 130


def _out(domain: str, name: str) -> str:
    folder = os.path.join(cfg.DOCS_DIR, domain, "figures")
    os.makedirs(folder, exist_ok=True)
    return os.path.join(folder, name)


def pump_pq_curve() -> str:
    """HPX-450 bench PQ + volumetric-efficiency curve (test at 1,000 RPM)."""
    flow = np.linspace(0, 32, 200)
    # Pressure (bar): ~360 plateau near 350 until ~18 L/min, then rolls off.
    pressure = 360 - 0.4 * flow
    pressure = np.where(flow > 18, 350 - 14.0 * (flow - 18), pressure)
    pressure = np.clip(pressure, 110, 365)
    # Volumetric efficiency (%): rises, peaks 88% at 24 L/min, slight decline.
    eff = 88 - 0.13 * (flow - 24) ** 2
    eff = np.clip(eff, 30, 88)

    fig, ax1 = plt.subplots(figsize=(7.2, 4.3))
    ax1.axvspan(15, 28, color="#d8efd8", alpha=0.7, label="Recommended band 15–28 L/min")
    ax1.plot(flow, pressure, color="#1f5fa8", lw=2.4, label="Outlet pressure")
    ax1.axhline(350, color="#1f5fa8", ls=":", lw=1.2)
    ax1.text(1, 352, "350 bar max continuous", color="#1f5fa8", fontsize=8, va="bottom")
    ax1.set_xlabel("Flow rate  Q  (L/min)")
    ax1.set_ylabel("Outlet pressure  (bar)", color="#1f5fa8")
    ax1.set_xlim(0, 32)
    ax1.set_ylim(100, 380)
    ax1.tick_params(axis="y", labelcolor="#1f5fa8")

    ax2 = ax1.twinx()
    ax2.plot(flow, eff, color="#c0392b", lw=2.4, label="Volumetric efficiency")
    ax2.set_ylabel("Volumetric efficiency  (%)", color="#c0392b")
    ax2.set_ylim(30, 100)
    ax2.tick_params(axis="y", labelcolor="#c0392b")
    ax2.plot(24, 88, "o", color="#c0392b", ms=7)
    ax2.annotate("peak η_vol 88% @ 24 L/min",
                 xy=(24, 88), xytext=(7.5, 70),
                 fontsize=9, color="#c0392b",
                 arrowprops=dict(arrowstyle="->", color="#c0392b"))

    ax1.set_title("HPX-450 — Bench PQ & Volumetric Efficiency (test @ 1,000 RPM)",
                  fontsize=11, weight="bold")
    ax1.grid(True, alpha=0.25)
    fig.tight_layout()
    path = _out("product-specs", "hpx450-pq-curve.png")
    fig.savefig(path, dpi=FIG_DPI)
    plt.close(fig)
    return path


def robot_zones() -> str:
    """RBX-7 collaborative safety zones (plan view) with explicit radii."""
    fig, ax = plt.subplots(figsize=(5.6, 5.6))
    zones = [
        (2.40, "#eef4fb", "Monitored zone  r = 2.40 m"),
        (1.60, "#fdf0d5", "Warning zone  r = 1.60 m  →  SLS 250 mm/s"),
        (0.90, "#f7d6d2", "Protective zone  r = 0.90 m  →  STO"),
    ]
    for r, color, _ in zones:
        ax.add_patch(Circle((0, 0), r, facecolor=color, edgecolor="#555", lw=1.3, zorder=1))
    for r, _, label in zones:
        ax.text(0, r - 0.12, label, ha="center", va="top", fontsize=8.5, zorder=3)
    # Robot base + reach marker.
    ax.add_patch(Circle((0, 0), 0.12, facecolor="#333", zorder=4))
    ax.text(0, -0.02, "RBX-7\nbase", ha="center", va="center", color="white", fontsize=7, zorder=5)
    ax.annotate("operator approach", xy=(1.60, 0), xytext=(2.3, 1.6),
                fontsize=8.5, arrowprops=dict(arrowstyle="->", color="#444"))
    ax.set_xlim(-2.7, 2.7)
    ax.set_ylim(-2.7, 2.7)
    ax.set_aspect("equal")
    ax.set_xlabel("metres from robot base")
    ax.set_title("RBX-7 — Collaborative Safety Zones (plan view)", fontsize=11, weight="bold")
    ax.grid(True, alpha=0.2)
    fig.tight_layout()
    path = _out("safety-compliance", "rbx7-collab-zones.png")
    fig.savefig(path, dpi=FIG_DPI)
    plt.close(fig)
    return path


def chiller_trend() -> str:
    """MNT-COOL-12 chiller return-temp stabilization trend with alarm band."""
    t = np.linspace(0, 15, 300)
    # Overshoot to ~20.4 C at t~3, settle to 20.0 by t~9.
    temp = 20.0 + 0.9 * np.exp(-t / 3.2) * np.cos(1.1 * t) + 0.02 * np.sin(2 * t)
    temp[0:1] = 21.2

    fig, ax = plt.subplots(figsize=(7.2, 4.3))
    ax.axhspan(19.7, 20.3, color="#d8efd8", alpha=0.8, label="Acceptance ±0.3 °C")
    ax.axhline(19.5, color="#c0392b", ls="--", lw=1.1)
    ax.axhline(20.5, color="#c0392b", ls="--", lw=1.1, label="Soft-alarm band ±0.5 °C")
    ax.axhline(20.0, color="#1f5fa8", ls=":", lw=1.2, label="Setpoint 20.0 °C")
    ax.plot(t, temp, color="#1f5fa8", lw=2.2, label="chiller.return_temp")
    ax.axvspan(0, 15, color="none")
    ax.annotate("overshoot 20.4 °C @ 3 min", xy=(3, 20.36), xytext=(5.2, 20.9),
                fontsize=8.5, arrowprops=dict(arrowstyle="->", color="#444"))
    ax.annotate("settled by 9 min", xy=(9, 20.0), xytext=(9.4, 19.55),
                fontsize=8.5, arrowprops=dict(arrowstyle="->", color="#444"))
    ax.set_xlabel("time after WARMUP-30  (min)")
    ax.set_ylabel("return temperature  (°C)")
    ax.set_xlim(0, 15)
    ax.set_ylim(19.2, 21.4)
    ax.set_title("MNT-COOL-12 — Chiller Return-Temp Stabilization", fontsize=11, weight="bold")
    ax.legend(loc="upper right", fontsize=7.5)
    ax.grid(True, alpha=0.25)
    fig.tight_layout()
    path = _out("maintenance-sops", "cool12-chiller-trend.png")
    fig.savefig(path, dpi=FIG_DPI)
    plt.close(fig)
    return path


def main() -> None:
    print("Rendering figures…")
    for fn in (pump_pq_curve, robot_zones, chiller_trend):
        path = fn()
        rel = os.path.relpath(path, cfg.DOCS_DIR)
        print(f"  wrote {rel}")
    print("Done. Re-run build_indexes.py to verbalize and index the figures.")


if __name__ == "__main__":
    main()
