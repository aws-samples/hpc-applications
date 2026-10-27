#!/usr/bin/env python3
"""
Generate the GROMACS performance charts of the May-June 2026 sweeps:

1. Arm chart: Graviton3E (c7gn.16xlarge, Neoverse V1) vs Graviton4
   (m8g.48xlarge, Neoverse V2) on benchPEP-h, 1 to 4 nodes.
2. GPU charts (disabled, see ``data_available_gpu``): three-family comparison
   g6e (L40S) vs g7e (Blackwell RTX PRO 6000) vs p5 (H100) per workload, plus a
   relative price-performance chart (us-east-2 on-demand prices).
3. GPU MPS chart: the aggregate throughput gain of N simulations sharing one
   g7e GPU, by system size.

The instance charts of the October 2026 runs, on the AMD types, are written by
``generate_instance_charts.py`` in this directory.

Every value below is relative: a configuration's performance against a
reference of the same workload (one Graviton3E node for Arm, the slowest family
on one GPU for GPU, one simulation for MPS), with its run count where the sweep
gives one. No absolute ``ns/day`` value appears here or on any chart.

Usage (from this directory):
    python3 generate_charts.py
"""

import sys

import matplotlib
matplotlib.use("Agg")  # write the PNGs without a display
import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Chart gating.
# ---------------------------------------------------------------------------
data_available_arm = True
# GPU (single-simulation multi-GPU scaling) charts are intentionally DISABLED.
# That approach anti-scaled (PCIe-bound) and is the wrong model for GROMACS.
# The GPU study was redone with NVIDIA MPS GPU-sharing — see ``data_available_mps``
# below. Do NOT re-enable this legacy gate.
data_available_gpu = False

# GPU MPS GPU-sharing charts (redone GPU study). Many independent simulations
# packed onto ONE GPU via NVIDIA CUDA MPS, reported as aggregate throughput
# gain (relative to a single sim) by system size.
# Measured on g7e (Blackwell RTX PRO 6000) in us-east-2, 2026-06-05.
data_available_mps = True

# ---------------------------------------------------------------------------
# Arm: benchPEP-h (12.5M atoms) on Graviton3E (c7gn.16xlarge, 64 cores per
# node) and Graviton4 (m8g.48xlarge, 192), us-east-2, May and June 2026,
# OpenMPI 5 on more than one node, mdrun -notunepme -resethway. Each value: the
# median rate of the configuration's runs over the median rate of one
# Graviton3E node (2 runs), higher is faster; and the run count. Graviton3E on
# 2 and 4 nodes ran 32 MPI ranks per node x 2 OpenMP threads, the fastest
# layout measured there; every other point one MPI rank per core.
# ---------------------------------------------------------------------------
ARM_NODES = [1, 2, 4]
ARM_DATA = {
    # workload: {instance type: {nodes: (relative performance, runs)}}
    "benchPEP-h": {
        "c7gn.16xlarge": {1: (1.00000, 2), 2: (1.96552, 1), 4: (3.87069, 3)},
        "m8g.48xlarge": {1: (2.47414, 3), 2: (4.87388, 2), 4: (9.55781, 2)},
    },
}
ARM_SUBTITLES = {
    "benchPEP-h": "benchPEP-h (~12,000,000 atoms, MPINAT peptide)",
}

# ---------------------------------------------------------------------------
# GPU: one simulation over 1 to 8 GPUs of one node (disabled, see
# ``data_available_gpu``). GROMACS v2026.1 / CUDA 13, g6e = L40S (sm_89),
# g7e = Blackwell RTX PRO 6000 (sm_120), p5 = H100 (sm_90), .48xlarge SKUs,
# us-east-2, 2026-06-01/02. Each value: the family's mean rate on that many
# GPUs over the mean rate of the slowest family on one GPU, same workload; and
# the run count. None: not charted.
#
# benchMEM (~80k atoms) ran on one GPU only: it is far too small to split
# across GPUs (two g6e GPUs ran it at 0.03x the rate of one).
# benchPEP-h (~12M atoms) ran with -notunepme (PME tuning does not converge by
# the -resethway midpoint on a system this large) and -npme 1 (a dedicated PME
# rank, required for multi-rank PME-on-GPU). These are single-node runs over
# PCIe (no NVLink on these SKUs), so even the 12M-atom system anti-scales:
# inter-GPU PME/PP traffic dominates, and the 1-GPU column is the comparison.
# ---------------------------------------------------------------------------
WORKLOADS = [
    ("benchMEM",   "benchMEM (~80,000 atoms, MPINAT membrane protein)"),
    ("benchPEP-h", "benchPEP-h (~12,000,000 atoms, MPINAT peptide)"),
]
GPU_COUNTS = [1, 2, 4, 8]
GPU_DATA = {
    # workload: {family: [(relative performance, runs) or None, per GPU count]}
    "benchMEM": {
        "g6e": [(1.12929, 2), None, None, None],
        "g7e": [(1.63980, 2), None, None, None],
        "p5":  [(1.00000, 2), None, None, None],
    },
    "benchPEP-h": {
        "g6e": [(1.00000, 2), (0.72067, 2), (0.24753, 2), (0.12108, 1)],
        "g7e": [(1.92044, 1), (1.27047, 2), (0.24739, 2), (0.12355, 2)],
        "p5":  [(1.19527, 2), (0.84451, 2), (0.24579, 2), (0.11890, 2)],
    },
}

# On-demand price of each family's 8-GPU .48xlarge SKU relative to
# g6e.48xlarge (us-east-2, 2026-06-01), for the relative price-performance
# chart only.
GPU_RELATIVE_PRICE = {
    "g6e": 1.00000,
    "g7e": 1.09990,
    "p5":  1.82675,
}

# ---------------------------------------------------------------------------
# GPU MPS GPU-sharing: N independent simulations sharing ONE g7e GPU
# (Blackwell RTX PRO 6000) through NVIDIA CUDA MPS, us-east-2, 2026-06-05,
# GROMACS v2026.1 / CUDA 13, nstlist=150, ntomp=1, --bind-to none,
# GPU_UPDATE=auto, -notunepme; cuda_graph=1 for villin and rnase_cubic, 0 for
# ion_channel. Each value: the aggregate throughput (the sum of the sims'
# rates) at 1, 2, 4 and 8 concurrent sims over that of one sim of the same
# system.
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

# g7e (Blackwell RTX PRO 6000): aggregate throughput relative to one sim.
MPS_G7E = {
    "villin":      [1.00000, 1.72859, 3.01446, 4.58065],
    "rnase_cubic": [1.00000, 1.75043, 2.77187, 3.60463],
    "ion_channel": [1.00000, 1.60991, 2.28793, 2.81115],
}

# ---------------------------------------------------------------------------
# Styling — match LAMMPS / WRF / OpenRadioss convention
# ---------------------------------------------------------------------------
BAR_W = 0.35
BASELINE_COLOR = "#4E79A7"     # Graviton3E (Arm)
COMPARISON_COLOR = "#F28E2B"   # Graviton4 (Arm)
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

# Arm: instance type -> (colour, legend label)
ARM_STYLE = {
    "c7gn.16xlarge": (BASELINE_COLOR, "c7gn.16xlarge (Graviton3E, 64 cores/node)"),
    "m8g.48xlarge": (COMPARISON_COLOR, "m8g.48xlarge (Graviton4, 192 cores/node)"),
}


# ---------------------------------------------------------------------------
# Arm chart renderer
# ---------------------------------------------------------------------------
def render_arm_chart(workload_subtitle, cells, output_filename, suptitle):
    """Paired bars per node count, relative to one Graviton3E node.

    ``cells`` maps an instance type to ``{nodes: (relative performance,
    runs)}``. A point measured by one run is drawn as a hatched bar.
    """
    fig, ax = plt.subplots(figsize=FIG_SIZE)
    x_pos = np.arange(len(ARM_NODES))
    families = list(cells)
    tallest = 1.0
    for fi, fam in enumerate(families):
        colour, label = ARM_STYLE[fam]
        offset = (fi - (len(families) - 1) / 2) * BAR_W
        for i, n in enumerate(ARM_NODES):
            if n not in cells[fam]:
                continue
            rel, runs = cells[fam][n]
            single = runs == 1
            ax.bar(i + offset, rel, BAR_W, color="white" if single else colour,
                   edgecolor=colour if single else EDGE_COLOR,
                   hatch="///" if single else None, linewidth=1.2,
                   label=label if i == 0 else None)
            ax.text(i + offset, rel + ANNOTATION_OFFSET, f"{rel:.2f}x",
                    ha="center", va="bottom",
                    fontsize=ANNOTATION_FONTSIZE, fontweight=ANNOTATION_WEIGHT)
            tallest = max(tallest, rel)

    ax.set_xticks(x_pos)
    ax.set_xticklabels([f"{n}N" for n in ARM_NODES])
    ax.set_xlabel("Number of nodes  (c7gn.16xlarge: 64 cores/node, m8g.48xlarge: 192)")
    ax.set_ylabel("Relative performance (1 x c7gn.16xlarge = 1.00, higher is faster)")
    ax.set_title(f"GROMACS — {workload_subtitle}", fontsize=TITLE_FONTSIZE)
    ax.grid(True, axis="y", linestyle=GRID_LINESTYLE, alpha=GRID_ALPHA)
    ax.legend(loc="upper left")
    ax.set_ylim(0, tallest * Y_HEADROOM)
    runs = [r for pts in cells.values() for (_, r) in pts.values()]
    runs_text = "Median of " + " or ".join(str(r) for r in sorted({r for r in runs if r > 1})) + " runs per bar"
    if 1 in runs:
        runs_text += "; hatched bar: 1 run"
    notes = [
        runs_text + ". Graviton3E on 2 and 4 nodes: 32 MPI ranks per node x 2 OpenMP threads,",
        "the fastest layout measured there; every other bar one rank per core. AWS runs of May and June 2026, "
        + "us-east-2.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=7.5, style="italic", color="dimgray",
             ha="left", va="bottom")
    fig.suptitle(suptitle, fontsize=SUPTITLE_FONTSIZE,
                 fontweight=SUPTITLE_WEIGHT, y=1.00)
    plt.tight_layout(rect=(0, 0.06, 1, 1))
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


def relative_values(cells):
    """The relative performance of each cell, or ``None`` where not charted."""
    return [c[0] if c else None for c in cells]


def render_three_family_gpu_chart(
    workload_id,
    workload_subtitle,
    gpu_counts,
    family_cells,
    output_filename,
    suptitle,
):
    """Render a grouped-bar chart across up to three GPU families.

    The values are relative to the slowest family on one GPU, so every
    rendered 1-GPU bar is >= 1.0x. Families/cells with no data are skipped
    without raising. Returns ``True`` if at least one bar was drawn.
    """
    present = {
        fam: relative_values(family_cells[fam])
        for fam in GPU_FAMILY_ORDER if fam in family_cells
    }
    one_gpu = [vals[0] for vals in present.values() if vals and vals[0] is not None]
    if not one_gpu:
        print(f"  skipping {output_filename} — no 1-GPU data for {workload_id}")
        return False
    baseline = min(one_gpu)

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    families_drawn = [
        fam for fam in GPU_FAMILY_ORDER
        if fam in present and any(v is not None for v in present[fam])
    ]
    n_fam = len(families_drawn)
    group_w = 0.8
    bar_w = group_w / max(n_fam, 1)
    x_pos = np.arange(len(gpu_counts))

    any_bar = False
    for fi, fam in enumerate(families_drawn):
        color, label = GPU_FAMILY_STYLE[fam]
        offset = (fi - (n_fam - 1) / 2) * bar_w
        heights = [(v / baseline) if v is not None else 0.0 for v in present[fam]]
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
    relative_price,
    output_filename,
    suptitle,
):
    """Render a relative price-performance chart.

    For each family and GPU count, the metric is the cell's relative
    performance over the family's relative on-demand price, against g6e on
    one GPU = 1.00. Skips cells/families with no data or no price without
    raising. Returns ``True`` if at least one bar was drawn.
    """
    if "g6e" not in family_cells or not family_cells["g6e"][0] or "g6e" not in relative_price:
        print(f"  skipping {output_filename} — no 1-GPU g6e reference for {workload_id}")
        return False
    reference = family_cells["g6e"][0][0] / relative_price["g6e"]

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    families_drawn = [
        fam for fam in GPU_FAMILY_ORDER
        if fam in family_cells and fam in relative_price
        and any(v is not None for v in relative_values(family_cells[fam]))
    ]
    n_fam = len(families_drawn)
    group_w = 0.8
    bar_w = group_w / n_fam
    x_pos = np.arange(len(gpu_counts))

    any_bar = False
    for fi, fam in enumerate(families_drawn):
        color, base_label = GPU_FAMILY_STYLE[fam]
        price = relative_price[fam]
        label = f"{base_label}  (price {price:.2f}x g6e)"
        offset = (fi - (n_fam - 1) / 2) * bar_w
        heights = [(v / price / reference) if v is not None else 0.0
                   for v in relative_values(family_cells[fam])]
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
    ax.set_ylabel("Relative price-performance (1 x g6e GPU = 1.00, higher is better)")
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
# Chart 1 — Arm: Graviton3E (c7gn) vs Graviton4 (m8g)
# ---------------------------------------------------------------------------
if data_available_arm:
    print("Arm charts (m8g vs c7gn):")
    for model_id, cells in ARM_DATA.items():
        render_arm_chart(
            workload_subtitle=ARM_SUBTITLES[model_id],
            cells=cells,
            output_filename=f"Gromacs-{model_id}-Graviton3VsGraviton4.png",
            suptitle="GROMACS — Graviton3E (c7gn) vs Graviton4 (m8g)   [GCC + OpenMPI 5 + EFA]",
        )
else:
    print("\nArm charts: skipped — set data_available_arm=True once the Arm "
          "sweep's relative values are in ARM_DATA.")

# ---------------------------------------------------------------------------
# Chart 2 — GPU three-family comparison (g6e / g7e / p5)
# Plus a relative price-performance chart per workload.
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

    print("\nGPU relative price-performance charts (us-east-2 on-demand prices):")
    for model_id, subtitle in WORKLOADS:
        render_gpu_price_perf_chart(
            workload_id=model_id,
            workload_subtitle=subtitle,
            gpu_counts=GPU_COUNTS,
            family_cells=GPU_DATA[model_id],
            relative_price=GPU_RELATIVE_PRICE,
            output_filename=f"Gromacs-{model_id}-GpuPricePerf.png",
            suptitle="GROMACS GPU price-performance — g6e vs g7e vs p5   "
                     "[us-east-2 on-demand, 8-GPU .48xlarge SKUs]",
        )
else:
    print("\nGPU charts: skipped — the single-simulation GPU charts are disabled "
          "(see data_available_gpu).")

# ---------------------------------------------------------------------------
# Chart 3 — GPU MPS GPU-sharing (the redone GPU study)
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
          "MPS sweep's relative values are in MPS_G7E.")

sys.exit(0)
