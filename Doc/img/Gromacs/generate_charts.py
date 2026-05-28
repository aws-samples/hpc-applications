#!/usr/bin/env python3
"""
Generate the GROMACS performance charts:

1. x86 chart: hpc8a (AMD EPYC Zen5) vs hpc7a (AMD EPYC Zen4) per workload
2. Arm chart (Phase 2): hpc7g (Graviton3E / Neoverse V1) vs m8g (Graviton4 /
   Neoverse V2) per workload — gated behind ``data_available_arm`` until the
   Arm sweep lands.
3. GPU chart (Phase 3): p5 (H100) vs g6e (L40S) per workload — gated behind
   ``data_available_gpu`` until the GPU sweep lands.

Workloads: ``benchMEM`` (~80k atoms, MPINAT membrane protein) and ``benchPEP-h``
(~12M atoms, MPINAT peptide). Each cell holds the per-replicate ``Performance:
<ns/day>`` values pulled from ``Gromacs_Benchmarks`` in DynamoDB (us-east-1).

Speedups are normalised to a single-node baseline of the same architecture
(1N hpc7a for x86, 1N hpc7g for Arm, 1-GPU g6e for GPU), matching the
LAMMPS / OpenRadioss / WRF convention used elsewhere in this repo. Only
speedups are rendered — absolute ``ns/day`` values do not appear on any chart
(see Requirement 12.2 in the spec).

Usage:
    python3 generate_charts.py

When a workload's per-replicate lists are still placeholders (all zeros / empty
lists), the script prints a "data not yet collected" message for that cell and
moves on cleanly — it never raises and never writes a meaningless PNG built
from sentinel values.
"""

import sys

import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Phase gating — flip these to ``True`` when the corresponding sweep has run
# and the per-replicate lists below have been populated from DynamoDB.
# ---------------------------------------------------------------------------
data_available_arm = False   # Phase 2 (hpc7g / m8g)
data_available_gpu = False   # Phase 3 (g6e / p5)

# ---------------------------------------------------------------------------
# Workload list. Each entry is ``(model_id, chart_subtitle)``. ``model_id`` is
# used verbatim in the output PNG filenames, so it must match the GROMACS
# ``MODEL`` value used by the benchmark scripts.
# ---------------------------------------------------------------------------
WORKLOADS = [
    ("benchMEM",   "benchMEM (~80,000 atoms, MPINAT membrane protein)"),
    ("benchPEP-h", "benchPEP-h (~12,000,000 atoms, MPINAT peptide)"),
]

# ---------------------------------------------------------------------------
# Node counts present in each sweep
# ---------------------------------------------------------------------------
NODES_X86 = [1, 2, 4]   # hpc7a / hpc8a
NODES_ARM = [1, 2, 4]   # hpc7g / m8g
GPU_COUNTS = [1, 2, 4, 8]  # g6e / p5 — single-node multi-GPU

# ---------------------------------------------------------------------------
# Measured data — Performance: <ns/day> per replicate.
#
# Pulled from DynamoDB table Gromacs_Benchmarks (us-east-1) once task 8.1 has
# completed. Each list is the per-replicate ``ns/day`` for a single
# (instance, node-count, model) cell. Use ``[]`` for cells that were not
# measured. Use sentinel zeros only as placeholders pending the live sweep.
#
# TODO(8.1): fill in from scan_sweep.sh output once task 8.1 has run live.
# ---------------------------------------------------------------------------

# x86 — benchMEM ----------------------------------------------------------
# hpc7a (Zen 4 / Genoa, OpenMPI 4) — eu-north-1 sweep, 2026-05-27/28
ns_hpc7a_1n_benchMEM = [224.622, 225.145]
ns_hpc7a_2n_benchMEM = [285.998, 288.425]
ns_hpc7a_4n_benchMEM = [321.734]   # r2 cancelled — fabric init stall on 4N hpc7a multi-node benchPEP-h-class workloads
# hpc8a (Zen5, OpenMPI 4) — eu-north-1 sweep, 2026-05-27/28
ns_hpc8a_1n_benchMEM = [372.860, 373.431]
ns_hpc8a_2n_benchMEM = [432.719, 486.112]
ns_hpc8a_4n_benchMEM = [459.658, 496.032, 507.975]   # 3 reps including the smoke-test run

# x86 — benchPEP-h --------------------------------------------------------
ns_hpc7a_1n_benchPEPh = [2.209, 2.406]
ns_hpc7a_2n_benchPEPh = [4.646]    # r2 cancelled — same 4N hpc7a multi-node hang
ns_hpc7a_4n_benchPEPh = []          # both replicates hit the 4N hpc7a multi-node startup hang
ns_hpc8a_1n_benchPEPh = [3.329, 3.438]
ns_hpc8a_2n_benchPEPh = [6.762, 6.838]
ns_hpc8a_4n_benchPEPh = []          # both reps + 2 retries cancelled — 4N hpc8a benchPEP-h hangs at multi-node startup

# Arm — benchMEM ----------------------------------------------------------
# hpc7g (Graviton3E, OpenMPI 4 or 5; default 5 in Phase 2)
ns_hpc7g_1n_benchMEM = []   # TODO(14.2)
ns_hpc7g_2n_benchMEM = []   # TODO(14.2)
ns_hpc7g_4n_benchMEM = []   # TODO(14.2)
# m8g (Graviton4, OpenMPI 5)
ns_m8g_1n_benchMEM   = []   # TODO(14.2)
ns_m8g_2n_benchMEM   = []   # TODO(14.2)
ns_m8g_4n_benchMEM   = []   # TODO(14.2)

# Arm — benchPEP-h --------------------------------------------------------
ns_hpc7g_1n_benchPEPh = []  # TODO(14.2)
ns_hpc7g_2n_benchPEPh = []  # TODO(14.2)
ns_hpc7g_4n_benchPEPh = []  # TODO(14.2)
ns_m8g_1n_benchPEPh   = []  # TODO(14.2)
ns_m8g_2n_benchPEPh   = []  # TODO(14.2)
ns_m8g_4n_benchPEPh   = []  # TODO(14.2)

# GPU — benchMEM ----------------------------------------------------------
# g6e (L40S, sm_89): per-GPU-count run on a single node
ns_g6e_1g_benchMEM = []     # TODO(19)
ns_g6e_2g_benchMEM = []     # TODO(19)
ns_g6e_4g_benchMEM = []     # TODO(19)
ns_g6e_8g_benchMEM = []     # TODO(19)
# p5 (H100, sm_90)
ns_p5_1g_benchMEM  = []     # TODO(19)
ns_p5_2g_benchMEM  = []     # TODO(19)
ns_p5_4g_benchMEM  = []     # TODO(19)
ns_p5_8g_benchMEM  = []     # TODO(19)

# GPU — benchPEP-h --------------------------------------------------------
ns_g6e_1g_benchPEPh = []    # TODO(19)
ns_g6e_2g_benchPEPh = []    # TODO(19)
ns_g6e_4g_benchPEPh = []    # TODO(19)
ns_g6e_8g_benchPEPh = []    # TODO(19)
ns_p5_1g_benchPEPh  = []    # TODO(19)
ns_p5_2g_benchPEPh  = []    # TODO(19)
ns_p5_4g_benchPEPh  = []    # TODO(19)
ns_p5_8g_benchPEPh  = []    # TODO(19)

# ---------------------------------------------------------------------------
# Per-workload lookup tables — keep numeric values out of matplotlib calls.
# ---------------------------------------------------------------------------
X86_DATA = {
    "benchMEM": {
        "hpc7a": [ns_hpc7a_1n_benchMEM, ns_hpc7a_2n_benchMEM, ns_hpc7a_4n_benchMEM],
        "hpc8a": [ns_hpc8a_1n_benchMEM, ns_hpc8a_2n_benchMEM, ns_hpc8a_4n_benchMEM],
    },
    "benchPEP-h": {
        "hpc7a": [ns_hpc7a_1n_benchPEPh, ns_hpc7a_2n_benchPEPh, ns_hpc7a_4n_benchPEPh],
        "hpc8a": [ns_hpc8a_1n_benchPEPh, ns_hpc8a_2n_benchPEPh, ns_hpc8a_4n_benchPEPh],
    },
}

ARM_DATA = {
    "benchMEM": {
        "hpc7g": [ns_hpc7g_1n_benchMEM, ns_hpc7g_2n_benchMEM, ns_hpc7g_4n_benchMEM],
        "m8g":   [ns_m8g_1n_benchMEM,   ns_m8g_2n_benchMEM,   ns_m8g_4n_benchMEM],
    },
    "benchPEP-h": {
        "hpc7g": [ns_hpc7g_1n_benchPEPh, ns_hpc7g_2n_benchPEPh, ns_hpc7g_4n_benchPEPh],
        "m8g":   [ns_m8g_1n_benchPEPh,   ns_m8g_2n_benchPEPh,   ns_m8g_4n_benchPEPh],
    },
}

GPU_DATA = {
    "benchMEM": {
        "g6e": [ns_g6e_1g_benchMEM, ns_g6e_2g_benchMEM, ns_g6e_4g_benchMEM, ns_g6e_8g_benchMEM],
        "p5":  [ns_p5_1g_benchMEM,  ns_p5_2g_benchMEM,  ns_p5_4g_benchMEM,  ns_p5_8g_benchMEM],
    },
    "benchPEP-h": {
        "g6e": [ns_g6e_1g_benchPEPh, ns_g6e_2g_benchPEPh, ns_g6e_4g_benchPEPh, ns_g6e_8g_benchPEPh],
        "p5":  [ns_p5_1g_benchPEPh,  ns_p5_2g_benchPEPh,  ns_p5_4g_benchPEPh,  ns_p5_8g_benchPEPh],
    },
}

# ---------------------------------------------------------------------------
# Styling — match LAMMPS / WRF / OpenRadioss convention
# ---------------------------------------------------------------------------
BAR_W = 0.35
BASELINE_COLOR = "#4E79A7"     # hpc7a (x86) / hpc7g (Arm) / g6e (GPU)
COMPARISON_COLOR = "#F28E2B"   # hpc8a (x86) / m8g  (Arm) / p5  (GPU)
EDGE_COLOR = "black"
GRID_LINESTYLE = "--"
GRID_ALPHA = 0.5
ANNOTATION_OFFSET = 0.04
ANNOTATION_FONTSIZE = 9
ANNOTATION_WEIGHT = "bold"
TITLE_FONTSIZE = 12
SUPTITLE_FONTSIZE = 13
SUPTITLE_WEIGHT = "bold"
Y_HEADROOM = 1.15  # 15% headroom above the tallest bar for annotation room
FIG_SIZE = (9, 6)
DPI = 150


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def cell_mean(values):
    """Return the mean of a non-empty, non-zero replicate list, else ``None``.

    A cell is considered "absent" — and skipped in the chart — if its
    replicate list is empty (no measurement attempted) or contains only
    sentinel zeros (placeholder pending live data collection). In both
    cases we return ``None`` so the caller can skip the bar without
    raising.
    """
    if not values:
        return None
    if all(v == 0 for v in values):
        return None
    return float(np.mean(values))


def collect_speedups(per_x_lists, x_values, baseline):
    """Return (xs_present, speedups) for cells with data.

    Speedup = ``ns/day_current / ns/day_baseline`` (higher is better).
    Cells whose replicate lists are empty/zero are skipped silently.
    """
    xs_present = []
    speedups = []
    for x, vals in zip(x_values, per_x_lists):
        m = cell_mean(vals)
        if m is None:
            continue
        xs_present.append(x)
        speedups.append(m / baseline)
    return xs_present, speedups


def render_two_instance_chart(
    workload_id,
    workload_subtitle,
    x_values,
    baseline_lists,
    comparison_lists,
    baseline_label,
    comparison_label,
    baseline_unit_label,
    x_axis_label,
    output_filename,
    suptitle,
):
    """Render a paired-bar speedup chart for a single workload.

    Returns ``True`` on success, ``False`` if the baseline 1-unit cell is
    missing (chart cannot be normalised, so we skip cleanly).
    """
    baseline_mean = cell_mean(baseline_lists[0])
    if baseline_mean is None:
        print(
            f"  skipping {output_filename} — baseline 1{baseline_unit_label} "
            f"{baseline_label} data not yet collected for {workload_id}"
        )
        return False

    base_xs, base_su = collect_speedups(baseline_lists, x_values, baseline_mean)
    cmp_xs,  cmp_su  = collect_speedups(comparison_lists, x_values, baseline_mean)

    # Use a unified x-axis covering every count present on either side so
    # missing cells leave a visible gap rather than collapsing the layout.
    all_xs = sorted(set(base_xs) | set(cmp_xs))
    base_lookup = dict(zip(base_xs, base_su))
    cmp_lookup  = dict(zip(cmp_xs,  cmp_su))
    base_bars = [base_lookup.get(x, 0.0) for x in all_xs]
    cmp_bars  = [cmp_lookup.get(x,  0.0) for x in all_xs]

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    x_pos = np.arange(len(all_xs))

    ax.bar(x_pos - BAR_W / 2, base_bars, BAR_W, color=BASELINE_COLOR,
           edgecolor=EDGE_COLOR, label=baseline_label)
    ax.bar(x_pos + BAR_W / 2, cmp_bars,  BAR_W, color=COMPARISON_COLOR,
           edgecolor=EDGE_COLOR, label=comparison_label)

    for i, v in enumerate(base_bars):
        if v > 0:
            ax.text(i - BAR_W / 2, v + ANNOTATION_OFFSET, f"{v:.2f}x",
                    ha="center", va="bottom",
                    fontsize=ANNOTATION_FONTSIZE, fontweight=ANNOTATION_WEIGHT)
    for i, v in enumerate(cmp_bars):
        if v > 0:
            ax.text(i + BAR_W / 2, v + ANNOTATION_OFFSET, f"{v:.2f}x",
                    ha="center", va="bottom",
                    fontsize=ANNOTATION_FONTSIZE, fontweight=ANNOTATION_WEIGHT)

    ax.set_xticks(x_pos)
    ax.set_xticklabels([f"{x}{baseline_unit_label}" for x in all_xs])
    ax.set_xlabel(x_axis_label)
    ax.set_ylabel(
        f"Speedup vs 1{baseline_unit_label} {baseline_label}  "
        "(higher is better)"
    )
    ax.set_title(f"GROMACS — {workload_subtitle}", fontsize=TITLE_FONTSIZE)
    ax.grid(True, axis="y", linestyle=GRID_LINESTYLE, alpha=GRID_ALPHA)
    ax.legend(loc="upper left")
    y_top = max(base_bars + cmp_bars + [1.0]) * Y_HEADROOM
    ax.set_ylim(0, y_top)

    fig.suptitle(suptitle, fontsize=SUPTITLE_FONTSIZE,
                 fontweight=SUPTITLE_WEIGHT, y=1.00)
    plt.tight_layout()
    plt.savefig(output_filename, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {output_filename}")
    return True


# ---------------------------------------------------------------------------
# Chart 1 — x86 hpc8a vs hpc7a (per workload)
# ---------------------------------------------------------------------------
print("x86 charts (hpc8a vs hpc7a):")
x86_rendered = 0
for model_id, subtitle in WORKLOADS:
    fname = f"Gromacs-{model_id}-Hpc8aVsHpc7a.png"
    cells = X86_DATA[model_id]
    ok = render_two_instance_chart(
        workload_id=model_id,
        workload_subtitle=subtitle,
        x_values=NODES_X86,
        baseline_lists=cells["hpc7a"],
        comparison_lists=cells["hpc8a"],
        baseline_label="hpc7a (AMD EPYC Zen4)",
        comparison_label="hpc8a (AMD EPYC Zen5)",
        baseline_unit_label="N",
        x_axis_label="Number of nodes (192 cores/node, both partitions)",
        output_filename=fname,
        suptitle="GROMACS — hpc8a (Zen5) vs hpc7a (Zen4)   "
                 "[GCC + OpenMPI 4 + EFA]",
    )
    if ok:
        x86_rendered += 1

if x86_rendered == 0:
    print("  no x86 charts rendered — fill in the per-replicate lists at the "
          "top of this script (TODO(8.1)) and re-run.")

# ---------------------------------------------------------------------------
# Chart 2 — Arm Graviton3E (hpc7g) vs Graviton4 (m8g) — Phase 2
# ---------------------------------------------------------------------------
if data_available_arm:
    print("\nArm charts (m8g vs hpc7g):")
    for model_id, subtitle in WORKLOADS:
        fname = f"Gromacs-{model_id}-Graviton3VsGraviton4.png"
        cells = ARM_DATA[model_id]
        render_two_instance_chart(
            workload_id=model_id,
            workload_subtitle=subtitle,
            x_values=NODES_ARM,
            baseline_lists=cells["hpc7g"],
            comparison_lists=cells["m8g"],
            baseline_label="hpc7g (Graviton3E, 64 c/n)",
            comparison_label="m8g (Graviton4, 192 c/n)",
            baseline_unit_label="N",
            x_axis_label="Number of nodes  (hpc7g: 64 c/n, m8g: 192 c/n)",
            output_filename=fname,
            suptitle="GROMACS — Graviton3E (hpc7g) vs Graviton4 (m8g)   "
                     "[GCC + OpenMPI 4/5 + EFA]",
        )
else:
    print("\nArm charts: skipped — set data_available_arm=True once Phase 2 "
          "sweep data has been pulled from DynamoDB (see task 14.2).")

# ---------------------------------------------------------------------------
# Chart 3 — GPU p5 (H100) vs g6e (L40S) — Phase 3
# ---------------------------------------------------------------------------
if data_available_gpu:
    print("\nGPU charts (p5 vs g6e):")
    for model_id, subtitle in WORKLOADS:
        fname = f"Gromacs-{model_id}-P5VsG6e.png"
        cells = GPU_DATA[model_id]
        render_two_instance_chart(
            workload_id=model_id,
            workload_subtitle=subtitle,
            x_values=GPU_COUNTS,
            baseline_lists=cells["g6e"],
            comparison_lists=cells["p5"],
            baseline_label="g6e (L40S, sm_89)",
            comparison_label="p5 (H100, sm_90)",
            baseline_unit_label="G",
            x_axis_label="Number of GPUs (single-node, NVLink/NVSwitch where present)",
            output_filename=fname,
            suptitle="GROMACS — p5 (H100) vs g6e (L40S)   "
                     "[CUDA 12 + GCC + OpenMPI]",
        )
else:
    print("\nGPU charts: skipped — set data_available_gpu=True once Phase 3 "
          "sweep data has been pulled from DynamoDB (see task 19).")

# ---------------------------------------------------------------------------
# Final exit. Empty/sentinel data is not an error condition — Phase 1
# generation should run cleanly even before the live sweep has been pulled.
# ---------------------------------------------------------------------------
sys.exit(0)
