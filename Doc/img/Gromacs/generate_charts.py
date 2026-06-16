#!/usr/bin/env python3
"""
Generate the GROMACS performance charts:

1. x86 chart: hpc8a (AMD EPYC Zen5) vs hpc7a (AMD EPYC Zen4) per workload
2. Arm chart (Phase 2): hpc7g (Graviton3E / Neoverse V1) vs m8g (Graviton4 /
   Neoverse V2) per workload — gated behind ``data_available_arm`` until the
   Arm sweep lands.
3. GPU chart (Phase 3): three-family comparison g6e (L40S) vs g7e (Blackwell
   RTX PRO 6000) vs p5 (H100) per workload, plus a price/performance chart
   (ns/day per dollar-hour, us-east-2 on-demand) — gated behind
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
data_available_arm = True    # Phase 2 (hpc7g / m8g) — populated 2026-05-29
# GPU (single-simulation multi-GPU scaling) charts are intentionally DISABLED.
# That approach anti-scaled (PCIe-bound) and is the wrong model for GROMACS.
# The GPU study was redone with NVIDIA MPS GPU-sharing — see ``data_available_mps``
# below. Do NOT re-enable this legacy gate.
data_available_gpu = False

# GPU MPS GPU-sharing charts (Phase 3, redone). Many independent simulations
# packed onto ONE GPU via NVIDIA CUDA MPS, reported as aggregate throughput
# gain (sum of per-sim ns/day, normalised to a single sim) by system size.
# Measured on g7e (Blackwell RTX PRO 6000) in us-east-2, 2026-06-05.
data_available_mps = True

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
# 4N cells collected pure-MPI (192 ranks/node, THREADS_PER_RANK=1) — consistent
# with the 1N/2N layout. The hybrid splits (96x2/48x4/24x8) hit the intermittent
# multi-node GROMACS startup hang on this preview cluster; pure-MPI ran reliably
# and is the published x86 layout. (eu-north-1, refilled 2026-06-16.)
ns_hpc7a_1n_benchPEPh = [2.209, 2.406]
ns_hpc7a_2n_benchPEPh = [4.646]
ns_hpc7a_4n_benchPEPh = [9.964]          # 4N 192x1 pure-MPI
ns_hpc8a_1n_benchPEPh = [3.329, 3.438]
ns_hpc8a_2n_benchPEPh = [6.762, 6.838]
ns_hpc8a_4n_benchPEPh = [13.735, 13.967, 14.105]   # 4N 192x1 pure-MPI, 3 reps

# Arm — benchMEM ----------------------------------------------------------
# hpc7g (Graviton3E / Neoverse V1, c7gn.16xlarge 64 c/n, OpenMPI 5) — us-east-2 sweep 2026-05-29
ns_hpc7g_1n_benchMEM = [77.814, 78.556]
ns_hpc7g_2n_benchMEM = [145.677, 146.755]
# 4N r-low (192.904) excluded as a confirmed outlier: 4 further reps clustered at
# 239.818 / 239.167 / 231.990 / 231.211 (~235 ns/day), the low rep was a noisy node.
ns_hpc7g_4n_benchMEM = [239.818, 239.167, 231.990, 231.211]
# m8g (Graviton4 / Neoverse V2, m8g.48xlarge 192 c/n, OpenMPI 5)
ns_m8g_1n_benchMEM   = [196.742, 197.413]
ns_m8g_2n_benchMEM   = [266.421, 301.490]
ns_m8g_4n_benchMEM   = [273.766, 280.428]

# Arm — benchPEP-h --------------------------------------------------------
# benchPEP-h (12M atoms) run with -notunepme -resethway: PME tuning does not
# converge by the -resethway midpoint on a system this large, so tuning is
# disabled for a fair, deterministic cross-arch comparison.
ns_hpc7g_1n_benchPEPh = [0.464, 0.464]
# hpc7g 2N/4N benchPEP-h collected with per-node-count LAYOUT TUNING (Activity 2+3,
# 2026-06-12/14). The 12M-atom system is fastest with a HYBRID 32 ranks/node x 2
# OMP-threads split, NOT pure-MPI 64x1 (which both underperforms and intermittently
# hangs at multi-node DD/PME startup on the 64-core Graviton3E nodes). Values below
# are the tuned optimum per node count:
#   2N: 32x2 = 0.912  (vs 8x8 0.833, 16x4 0.777)
#   4N: 32x2 = 1.792  (vs 8x8 1.512)
ns_hpc7g_2n_benchPEPh = [0.912]
ns_hpc7g_4n_benchPEPh = [1.792]
ns_m8g_1n_benchPEPh   = [1.147, 1.148]
ns_m8g_2n_benchPEPh   = [2.255, 2.268]
ns_m8g_4n_benchPEPh   = [4.407, 4.463]

# GPU — benchMEM ----------------------------------------------------------
# Single-node multi-GPU scaling, GROMACS v2026.1 / CUDA 13. ns/day per
# replicate. g6e = L40S (sm_89), g7e = Blackwell RTX PRO 6000 (sm_120),
# p5 = H100 (sm_90). Measured on hpc-4 (us-east-2), .48xlarge SKUs, 2026-06-01/02.
#
# benchMEM (~80k atoms) is run 1-GPU ONLY: it is far too small to split
# across GPUs, so multi-GPU anti-scales hard and stalls. Evidence: g6e
# 2-GPU measured 8.0 ns/day vs 1-GPU 265 ns/day (recorded below as a comment,
# not charted). We therefore present benchMEM as a single-GPU throughput
# comparison only.
# g6e (L40S)
ns_g6e_1g_benchMEM = [264.744, 265.445]
ns_g6e_2g_benchMEM = []     # anti-scales (measured 8.003, 8.014) — not charted
ns_g6e_4g_benchMEM = []     # not run (anti-scaling, too small to split)
ns_g6e_8g_benchMEM = []     # not run
# g7e (Blackwell RTX PRO 6000)
ns_g7e_1g_benchMEM = [383.187, 386.679]
ns_g7e_2g_benchMEM = []     # not run
ns_g7e_4g_benchMEM = []     # not run
ns_g7e_8g_benchMEM = []     # not run
# p5 (H100)
ns_p5_1g_benchMEM  = [232.040, 237.447]
ns_p5_2g_benchMEM  = []     # not run
ns_p5_4g_benchMEM  = []     # not run
ns_p5_8g_benchMEM  = []     # not run

# GPU — benchPEP-h --------------------------------------------------------
# benchPEP-h (~12M atoms), full 1/2/4/8-GPU scaling, run with -notunepme
# (PME tuning does not converge by the -resethway midpoint on a system this
# large) and -npme 1 (dedicated PME rank, required for multi-rank PME-on-GPU).
# NOTE: these are single-node multi-GPU runs over PCIe (no NVLink on these
# SKUs), so even the 12M-atom system anti-scales — inter-GPU PME/PP traffic
# dominates. The 1-GPU column is the meaningful raw-throughput comparison.
# g6e (L40S)
ns_g6e_1g_benchPEPh = [3.436, 3.452]
ns_g6e_2g_benchPEPh = [2.477, 2.487]
ns_g6e_4g_benchPEPh = [0.850, 0.855]
ns_g6e_8g_benchPEPh = [0.417]            # r2 not parseable (transient); r1 valid
# g7e (Blackwell)
ns_g7e_1g_benchPEPh = [6.614]            # r1 not parseable (transient); r2 valid
ns_g7e_2g_benchPEPh = [4.390, 4.361]
ns_g7e_4g_benchPEPh = [0.855, 0.849]
ns_g7e_8g_benchPEPh = [0.425, 0.426]
# p5 (H100)
ns_p5_1g_benchPEPh  = [4.117, 4.116]
ns_p5_2g_benchPEPh  = [2.899, 2.918]
ns_p5_4g_benchPEPh  = [0.847, 0.846]
ns_p5_8g_benchPEPh  = [0.410, 0.409]

# ---------------------------------------------------------------------------
# GPU instance on-demand pricing — us-east-2, retrieved 2026-06-01.
# Used only for the price/performance chart (ns/day per dollar-hour). The
# .48xlarge SKU is the one swept (8 GPUs/node) for all three families.
# Keep prices out of matplotlib calls (Requirement 12.10).
# ---------------------------------------------------------------------------
GPU_PRICE_USD_PER_HR = {
    "g6e": 30.13,   # g6e.48xlarge (8x L40S)
    "g7e": 33.14,   # g7e.48xlarge (8x Blackwell RTX PRO 6000)
    "p5":  55.04,   # p5.48xlarge  (8x H100)
}

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
        "g7e": [ns_g7e_1g_benchMEM, ns_g7e_2g_benchMEM, ns_g7e_4g_benchMEM, ns_g7e_8g_benchMEM],
        "p5":  [ns_p5_1g_benchMEM,  ns_p5_2g_benchMEM,  ns_p5_4g_benchMEM,  ns_p5_8g_benchMEM],
    },
    "benchPEP-h": {
        "g6e": [ns_g6e_1g_benchPEPh, ns_g6e_2g_benchPEPh, ns_g6e_4g_benchPEPh, ns_g6e_8g_benchPEPh],
        "g7e": [ns_g7e_1g_benchPEPh, ns_g7e_2g_benchPEPh, ns_g7e_4g_benchPEPh, ns_g7e_8g_benchPEPh],
        "p5":  [ns_p5_1g_benchPEPh,  ns_p5_2g_benchPEPh,  ns_p5_4g_benchPEPh,  ns_p5_8g_benchPEPh],
    },
}

# ---------------------------------------------------------------------------
# GPU MPS GPU-sharing data — aggregate throughput (sum of per-sim ns/day) for
# N independent simulations sharing ONE GPU via NVIDIA CUDA MPS. Measured in
# us-east-2 (2026-06-05), GROMACS v2026.1 / CUDA 13, nstlist=150, ntomp=1,
# --bind-to none, GPU_UPDATE=auto, -notunepme. cuda_graph=1 for villin/
# rnase_cubic, =0 for ion_channel.
#
# Systems span the GPU-utilization range where MPS matters: villin (~5K atoms,
# heavily under-utilizes a modern GPU) → ion_channel (~149K atoms, closer to
# saturating one GPU). NPROC is the number of concurrent sims packed on the GPU.
# ---------------------------------------------------------------------------
MPS_NPROC = [1, 2, 4, 8]

MPS_SYSTEMS = [
    ("villin",       "Villin (~5,000 atoms)"),
    ("rnase_cubic",  "RNase-cubic (~24,000 atoms)"),
    ("ion_channel",  "Ion-channel (~149,000 atoms)"),
]

# g7e (Blackwell RTX PRO 6000) aggregate ns/day by concurrent-sim count.
MPS_G7E = {
    "villin":      [2697, 4662, 8130, 12354],
    "rnase_cubic": [1166, 2041, 3232, 4203],
    "ion_channel": [323,  520,  739,  908],
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


# Per-family colors for the three-way GPU charts.
GPU_FAMILY_STYLE = {
    "g6e": ("#4E79A7", "g6e (L40S, sm_89)"),
    "g7e": ("#59A14F", "g7e (Blackwell RTX PRO 6000, sm_120)"),
    "p5":  ("#F28E2B", "p5 (H100, sm_90)"),
}
GPU_FAMILY_ORDER = ["g6e", "g7e", "p5"]


def render_three_family_gpu_chart(
    workload_id,
    workload_subtitle,
    gpu_counts,
    family_cells,
    output_filename,
    suptitle,
):
    """Render a grouped-bar speedup chart across up to three GPU families.

    Speedup is normalised to the slowest family's 1-GPU mean so all three
    families share one baseline (Requirement 12.5). Families/cells with no
    data are skipped without raising. Returns ``True`` if at least one bar
    was drawn.
    """
    present = {
        fam: [cell_mean(c) for c in family_cells[fam]]
        for fam in GPU_FAMILY_ORDER if fam in family_cells
    }
    # Baseline = the smallest 1-GPU mean among families that have one, so
    # every rendered family is >= 1.0x and the comparison is like-for-like.
    one_gpu_means = [
        means[0] for means in present.values()
        if means and means[0] is not None
    ]
    if not one_gpu_means:
        print(f"  skipping {output_filename} — no 1-GPU data for {workload_id}")
        return False
    baseline = min(one_gpu_means)

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    families_drawn = [
        fam for fam in GPU_FAMILY_ORDER
        if fam in present and any(m is not None for m in present[fam])
    ]
    n_fam = len(families_drawn)
    group_w = 0.8
    bar_w = group_w / max(n_fam, 1)
    x_pos = np.arange(len(gpu_counts))

    any_bar = False
    for fi, fam in enumerate(families_drawn):
        color, label = GPU_FAMILY_STYLE[fam]
        means = present[fam]
        offset = (fi - (n_fam - 1) / 2) * bar_w
        heights = [(m / baseline) if m is not None else 0.0 for m in means]
        ax.bar(x_pos + offset, heights, bar_w, color=color,
               edgecolor=EDGE_COLOR, label=label)
        for i, h in enumerate(heights):
            if h > 0:
                any_bar = True
                ax.text(i + offset, h + ANNOTATION_OFFSET, f"{h:.2f}x",
                        ha="center", va="bottom",
                        fontsize=ANNOTATION_FONTSIZE - 1,
                        fontweight=ANNOTATION_WEIGHT)

    if not any_bar:
        plt.close(fig)
        print(f"  skipping {output_filename} — no data for {workload_id}")
        return False

    ax.set_xticks(x_pos)
    ax.set_xticklabels([f"{g}G" for g in gpu_counts])
    ax.set_xlabel("Number of GPUs (single-node)")
    ax.set_ylabel("Speedup vs slowest 1-GPU family  (higher is better)")
    ax.set_title(f"GROMACS — {workload_subtitle}", fontsize=TITLE_FONTSIZE)
    ax.grid(True, axis="y", linestyle=GRID_LINESTYLE, alpha=GRID_ALPHA)
    ax.legend(loc="upper left", fontsize=8)
    fig.suptitle(suptitle, fontsize=SUPTITLE_FONTSIZE,
                 fontweight=SUPTITLE_WEIGHT, y=1.00)
    plt.tight_layout()
    plt.savefig(output_filename, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {output_filename}")
    return True


def render_gpu_price_perf_chart(
    workload_id,
    workload_subtitle,
    gpu_counts,
    family_cells,
    price_per_hr,
    output_filename,
    suptitle,
):
    """Render a price/performance chart: ns/day per US dollar-hour.

    For each family and GPU count, the metric is
    ``mean(ns/day) / hourly_price`` (Requirement 12.9). Absolute ns/day is
    never rendered. Skips cells/families with no data or no price without
    raising. Returns ``True`` if at least one bar was drawn.
    """
    fig, ax = plt.subplots(figsize=FIG_SIZE)
    families_drawn = [
        fam for fam in GPU_FAMILY_ORDER
        if fam in family_cells and fam in price_per_hr
        and any(cell_mean(c) is not None for c in family_cells[fam])
    ]
    n_fam = len(families_drawn)
    if n_fam == 0:
        plt.close(fig)
        print(f"  skipping {output_filename} — no priced data for {workload_id}")
        return False

    group_w = 0.8
    bar_w = group_w / n_fam
    x_pos = np.arange(len(gpu_counts))

    any_bar = False
    for fi, fam in enumerate(families_drawn):
        color, base_label = GPU_FAMILY_STYLE[fam]
        price = price_per_hr[fam]
        label = f"{base_label}  (${price:.2f}/hr)"
        means = [cell_mean(c) for c in family_cells[fam]]
        offset = (fi - (n_fam - 1) / 2) * bar_w
        heights = [(m / price) if m is not None else 0.0 for m in means]
        ax.bar(x_pos + offset, heights, bar_w, color=color,
               edgecolor=EDGE_COLOR, label=label)
        for i, h in enumerate(heights):
            if h > 0:
                any_bar = True
                ax.text(i + offset, h * (1 + ANNOTATION_OFFSET), f"{h:.2f}",
                        ha="center", va="bottom",
                        fontsize=ANNOTATION_FONTSIZE - 1,
                        fontweight=ANNOTATION_WEIGHT)

    if not any_bar:
        plt.close(fig)
        print(f"  skipping {output_filename} — no data for {workload_id}")
        return False

    ax.set_xticks(x_pos)
    ax.set_xticklabels([f"{g}G" for g in gpu_counts])
    ax.set_xlabel("Number of GPUs (single-node)")
    ax.set_ylabel("ns/day per $/hr  (higher is better)")
    ax.set_title(f"GROMACS — {workload_subtitle}", fontsize=TITLE_FONTSIZE)
    ax.grid(True, axis="y", linestyle=GRID_LINESTYLE, alpha=GRID_ALPHA)
    ax.legend(loc="upper right", fontsize=8)
    fig.suptitle(suptitle, fontsize=SUPTITLE_FONTSIZE,
                 fontweight=SUPTITLE_WEIGHT, y=1.00)
    plt.tight_layout()
    plt.savefig(output_filename, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {output_filename}")
    return True


# ---------------------------------------------------------------------------
# MPS chart renderers
# ---------------------------------------------------------------------------
def render_mps_gain_chart(
    nproc_counts,
    systems,
    family_label,
    per_system_aggregate,
    output_filename,
    suptitle,
):
    """Render the MPS throughput-gain chart for one GPU family.

    For each system, the bars show aggregate throughput at 1/2/4/8 concurrent
    sims normalised to that system's own 1-sim aggregate, i.e. the *MPS gain*
    (how much extra total throughput MPS unlocks by packing more independent
    sims onto the GPU). Normalising per-system keeps every curve starting at
    1.0x so the differing absolute ns/day across system sizes does not appear
    on the chart. Returns ``True`` if at least one bar was drawn.
    """
    drawn_systems = [
        (sid, sub) for sid, sub in systems
        if sid in per_system_aggregate and per_system_aggregate[sid]
        and per_system_aggregate[sid][0]
    ]
    if not drawn_systems:
        print(f"  skipping {output_filename} — no MPS data")
        return False

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    n_sys = len(drawn_systems)
    group_w = 0.8
    bar_w = group_w / n_sys
    x_pos = np.arange(len(nproc_counts))
    palette = ["#4E79A7", "#F28E2B", "#59A14F", "#E15759"]

    any_bar = False
    for si, (sid, sub) in enumerate(drawn_systems):
        agg = per_system_aggregate[sid]
        baseline = agg[0]
        offset = (si - (n_sys - 1) / 2) * bar_w
        heights = [(a / baseline) if a else 0.0 for a in agg]
        ax.bar(x_pos + offset, heights, bar_w, color=palette[si % len(palette)],
               edgecolor=EDGE_COLOR, label=sub)
        for i, h in enumerate(heights):
            if h > 0:
                any_bar = True
                ax.text(i + offset, h + ANNOTATION_OFFSET, f"{h:.1f}x",
                        ha="center", va="bottom",
                        fontsize=ANNOTATION_FONTSIZE - 1,
                        fontweight=ANNOTATION_WEIGHT)

    if not any_bar:
        plt.close(fig)
        print(f"  skipping {output_filename} — no MPS data")
        return False

    ax.set_xticks(x_pos)
    ax.set_xticklabels([f"{n}" for n in nproc_counts])
    ax.set_xlabel("Concurrent simulations sharing one GPU (NVIDIA MPS)")
    ax.set_ylabel("Aggregate throughput vs 1 sim  (higher is better)")
    ax.set_title(f"GROMACS MPS throughput gain — {family_label}",
                 fontsize=TITLE_FONTSIZE)
    ax.grid(True, axis="y", linestyle=GRID_LINESTYLE, alpha=GRID_ALPHA)
    ax.legend(loc="upper left", fontsize=9)
    y_top = max(
        [a / per_system_aggregate[sid][0]
         for sid, _ in drawn_systems
         for a in per_system_aggregate[sid] if per_system_aggregate[sid][0]]
        + [1.0]
    ) * Y_HEADROOM
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
# Chart 3 — GPU three-family comparison (g6e / g7e / p5) — Phase 3
# Plus a price/performance chart (ns/day per dollar-hour) per workload.
# ---------------------------------------------------------------------------
if data_available_gpu:
    print("\nGPU performance charts (g6e vs g7e vs p5):")
    for model_id, subtitle in WORKLOADS:
        render_three_family_gpu_chart(
            workload_id=model_id,
            workload_subtitle=subtitle,
            gpu_counts=GPU_COUNTS,
            family_cells=GPU_DATA[model_id],
            output_filename=f"Gromacs-{model_id}-G6eVsG7eVsP5.png",
            suptitle="GROMACS — g6e (L40S) vs g7e (Blackwell) vs p5 (H100)   "
                     "[CUDA 13 + GCC 14, GROMACS v2026.1]",
        )

    print("\nGPU price/performance charts (ns/day per $/hr, us-east-2):")
    for model_id, subtitle in WORKLOADS:
        render_gpu_price_perf_chart(
            workload_id=model_id,
            workload_subtitle=subtitle,
            gpu_counts=GPU_COUNTS,
            family_cells=GPU_DATA[model_id],
            price_per_hr=GPU_PRICE_USD_PER_HR,
            output_filename=f"Gromacs-{model_id}-GpuPricePerf.png",
            suptitle="GROMACS GPU price/performance — g6e vs g7e vs p5   "
                     "[us-east-2 on-demand, 8-GPU .48xlarge SKUs]",
        )
else:
    print("\nGPU charts: skipped — set data_available_gpu=True once the Phase 3 "
          "sweep results have been filled into the ns_* lists (see task 20.1).")

# ---------------------------------------------------------------------------
# Chart 4 — GPU MPS GPU-sharing (Phase 3, redone)
#   MPS throughput-gain vs system size (g7e), one bar group per system
# ---------------------------------------------------------------------------
if data_available_mps:
    print("\nGPU MPS throughput-gain chart (g7e, by system size):")
    render_mps_gain_chart(
        nproc_counts=MPS_NPROC,
        systems=MPS_SYSTEMS,
        family_label="g7e (Blackwell RTX PRO 6000)",
        per_system_aggregate=MPS_G7E,
        output_filename="Gromacs-MPS-ThroughputGain-G7e.png",
        suptitle="GROMACS NVIDIA MPS — aggregate throughput gain by system size   "
                 "[g7e Blackwell, CUDA 13, GROMACS v2026.1]",
    )
else:
    print("\nGPU MPS charts: skipped — set data_available_mps=True once the "
          "MPS sweep results have been filled into the MPS_* tables.")

# ---------------------------------------------------------------------------
# Final exit. Empty/sentinel data is not an error condition — Phase 1
# generation should run cleanly even before the live sweep has been pulled.
# ---------------------------------------------------------------------------
sys.exit(0)
