#!/usr/bin/env python3
"""
Generate the OpenFOAM scaling charts of apps/OpenFoam/README.md, one per mesh of
the OCC DrivAer static-mesh case (simpleFoam, 200 iterations):

    OpenFOAM-OCCDrivAer-236M-Scaling.png   236M cells
    OpenFOAM-OCCDrivAer-65M-Scaling.png    65M cells

Each chart shows six instance types on 1 to 16 nodes: the relative performance
against one hpc7a.96xlarge node running the same mesh (= 1.00, higher is
faster), next to each type's parallel efficiency against its own smallest node
count, with the 60% line below which scaling stops paying.

Timing basis: the simpleFoam phase (from the mpirun that starts simpleFoam to
its exit), not the job's total. Per configuration (instance type, node count)
the median over its runs is taken; relative performance = the 1 x
hpc7a.96xlarge median / the configuration's median. Only relative values and
run counts are embedded here.

Usage (from this directory):
    python3 generate_openfoam_charts.py
"""

import matplotlib

matplotlib.use("Agg")  # write the PNGs without a display
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data: relative performance (1 x hpc7a.96xlarge of the same mesh =
# 1.00) and run count per node count. OpenFOAM v2512, OCC DrivAer static mesh,
# 200 SIMPLE iterations, every node fully populated with one MPI rank per core,
# over EFA:
#   x86        the GCC 14 AVX-512 build (Option 1) with OpenMPI 4.1.7, except
#              hpc6a.48xlarge: the AVX2 build (Option 3) with OpenMPI 4.1.7
#   Graviton4  the GCC 14 build with OpenMPI 5.0.9
# AWS runs of October 2026, except hpc8a.96xlarge on the 236M mesh: May 2026.
# ---------------------------------------------------------------------------
DATA = {
    "236M": {
        # type             {nodes: (relative performance, runs)}
        "hpc8a.96xlarge": {1: (1.3888, 3), 2: (2.7757, 4), 4: (5.0125, 3), 8: (8.0845, 3), 16: (9.8495, 1)},
        "c8i.96xlarge":   {1: (1.5242, 3), 2: (2.8754, 3)},
        "m8a.48xlarge":   {1: (1.3803, 1)},
        "m8g.48xlarge":   {1: (1.3532, 4), 2: (2.4904, 2), 4: (4.4385, 2), 8: (6.4157, 2)},
        "hpc7a.96xlarge": {1: (1.0000, 2), 2: (1.9290, 2), 4: (3.5875, 2), 8: (5.6086, 2), 16: (6.7430, 2)},
        "hpc6a.48xlarge": {2: (0.8415, 3), 4: (1.5789, 3), 8: (2.5682, 3), 16: (3.5061, 3)},
    },
    "65M": {
        "hpc8a.96xlarge": {1: (1.3985, 3), 2: (2.8461, 3), 4: (4.7685, 3), 8: (6.2887, 3)},
        "c8i.96xlarge":   {1: (1.6984, 3), 2: (2.6804, 3)},
        "m8a.48xlarge":   {1: (1.3545, 1)},
        "m8g.48xlarge":   {1: (1.2852, 2), 2: (2.3894, 2), 4: (4.1001, 2), 8: (4.8426, 1)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.9923, 3), 4: (3.7709, 3), 8: (5.3150, 3)},
        "hpc6a.48xlarge": {1: (0.4100, 3), 2: (0.8420, 3), 4: (1.6478, 3), 8: (2.6025, 3), 16: (3.4470, 3)},
    },
}

# Runs of another month than the rest of a chart: named in that chart's notes.
MONTH_NOTES = {
    "236M": "hpc8a.96xlarge: May 2026, with the same build options and MPI",
}

# type: (legend label, colour, marker)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 cores/node)", "#232F3E", "o"),
    "c8i.96xlarge":   ("c8i.96xlarge (192)", "#59A14F", "D"),
    "m8a.48xlarge":   ("m8a.48xlarge (192)", "#E15759", "v"),
    "m8g.48xlarge":   ("m8g.48xlarge (192, Graviton4)", "#4E79A7", "^"),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s"),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P"),
}

# Value labels at a line's last point: (dx, dy) in points, per mesh, for the left
# panel (relative performance) and the right one (efficiency); a negative dx puts
# the label left of the point. A type with no entry gets no label.
LABELS = {
    "236M": {
        "hpc8a.96xlarge": ((7, 0), (7, 4)),
        "c8i.96xlarge":   ((-6, 9), (7, 0)),
        "m8g.48xlarge":   ((7, -2), (7, 0)),
        "hpc7a.96xlarge": ((7, 0), (7, -6)),
        "hpc6a.48xlarge": ((7, 0), (7, 6)),
    },
    "65M": {
        "hpc8a.96xlarge": ((7, 6), (7, 3)),
        "c8i.96xlarge":   ((-6, 9), (7, 0)),
        "m8g.48xlarge":   ((7, -7), (7, -3)),
        "hpc7a.96xlarge": ((7, -1), (7, 0)),
        "hpc6a.48xlarge": ((7, 0), (7, 0)),
    },
}

NODES = [1, 2, 4, 8, 16]
KNEE = 60  # parallel efficiency, %, below which scaling stops paying
FIG_SIZE = (15, 6.8)
DPI = 150


def efficiency(points):
    """Speed-up over the type's own smallest node count, divided by the node-count ratio."""
    n0 = min(points)
    return {n: (rel / points[n0][0]) / (n / n0) for n, (rel, _) in points.items()}


def plot_series(ax, nodes, values, runs, colour, marker, label):
    """One line per type; a hollow marker, drawn above the others, where a point was measured by one run."""
    ax.plot(nodes, values, "-", color=colour, linewidth=2, label=label, zorder=2)
    for xv, yv, r in zip(nodes, values, runs):
        ax.plot([xv], [yv], marker=marker, markersize=8, color=colour, markeredgecolor=colour,
                markeredgewidth=1.5, markerfacecolor=colour if r > 1 else "white", zorder=3 if r > 1 else 4)


def end_label(ax, x, y, text, offset, colour):
    if offset is not None:
        ax.annotate(text, (x, y), xytext=offset, textcoords="offset points", ha="left" if offset[0] >= 0 else "right",
                    va="center", fontsize=9, fontweight="bold", color=colour)


def node_axis(ax):
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(NODES))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.set_xlim(0.85, 24)
    ax.set_xlabel("Number of nodes (every node fully populated)")
    ax.grid(True, which="major", linestyle="--", alpha=0.5)


def join_words(words):
    """'a', 'a and b', 'a, b and c'."""
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]


def chart(mesh, output):
    data = DATA[mesh]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=FIG_SIZE)

    # --- Left: relative performance ----------------------------------------------
    for itype, points in data.items():
        label, colour, marker = STYLE[itype]
        nodes = sorted(points)
        rel = [points[n][0] for n in nodes]
        plot_series(ax1, nodes, rel, [points[n][1] for n in nodes], colour, marker, label)
        offset = LABELS[mesh].get(itype, (None, None))[0]
        end_label(ax1, nodes[-1], rel[-1], f"{rel[-1]:.2f}", offset, colour)
    node_axis(ax1)
    ax1.set_yscale("log", base=2)
    ax1.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4, 8]))
    ax1.yaxis.set_minor_locator(NullLocator())
    ax1.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax1.set_ylim(0.3, 14)
    ax1.set_ylabel("Relative performance (1 x hpc7a.96xlarge = 1.00, higher is faster)")
    ax1.set_title("Relative performance")
    ax1.legend(loc="upper left", fontsize=9)

    # --- Right: parallel efficiency (types measured on more than one node count) ---
    for itype, points in data.items():
        if len(points) < 2:
            continue
        label, colour, marker = STYLE[itype]
        eff = efficiency(points)
        nodes = sorted(eff)
        pct = [100 * eff[n] for n in nodes]
        plot_series(ax2, nodes, pct, [points[n][1] for n in nodes], colour, marker, label)
        offset = LABELS[mesh].get(itype, (None, None))[1]
        end_label(ax2, nodes[-1], pct[-1], f"{pct[-1]:.0f}%", offset, colour)
    node_axis(ax2)
    ax2.axhline(100, color="gray", linestyle=":", linewidth=1.2, zorder=1)
    ax2.axhline(KNEE, color="#C0392B", linestyle="--", linewidth=1.2, zorder=1)
    ax2.annotate(f"{KNEE}%: below it, scaling stops paying", (0.9, KNEE), xytext=(0, -12),
                 textcoords="offset points", fontsize=9, color="#C0392B", ha="left", va="center")
    ax2.set_ylim(30, 110)
    ax2.set_ylabel("Parallel efficiency (%)")
    ax2.set_title("Parallel efficiency against each type's smallest node count")

    # --- Notes: the metric, the run counts, the months ------------------------------
    multi = sorted({runs for points in data.values() for _, runs in points.values() if runs > 1})
    single = [f"{t} on {join_words([str(n) for n in sorted(p) if p[n][1] == 1])} "
              + ("node" if [n for n in p if p[n][1] == 1] == [1] else "nodes")
              for t, p in data.items() if any(r == 1 for _, r in p.values())]
    smallest = [f"{t}: {min(p)} nodes" for t, p in data.items() if len(p) > 1 and min(p) != 1]
    notes = [
        "simpleFoam phase, 200 iterations. Filled markers: median of "
        + join_words([str(r) for r in multi]).replace(" and ", " or ") + " runs; hollow markers: 1 run ("
        + "; ".join(single) + ").",
        ("Efficiency: the speed-up over the type's own smallest node count (1 node; " + "; ".join(smallest)
         + "), divided by the node-count ratio." if smallest
         else "Efficiency: the speed-up over one node of the same type, divided by the node count."),
        "One MPI rank per core, OpenMPI over EFA; AWS runs of October 2026"
        + (", except " + MONTH_NOTES[mesh] if mesh in MONTH_NOTES else "") + ".",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")

    title = f"OpenFOAM v2512, OCC DrivAer {mesh} cells (simpleFoam, 200 iterations): scaling on six instance types"
    fig.suptitle(title, fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.08, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


chart("236M", "OpenFOAM-OCCDrivAer-236M-Scaling.png")
chart("65M", "OpenFOAM-OCCDrivAer-65M-Scaling.png")

# ---------------------------------------------------------------------------
# Also print a summary table for reference (the README's tables)
# ---------------------------------------------------------------------------
for mesh, data in DATA.items():
    print(f"\n=== {mesh}: relative performance (1 x hpc7a.96xlarge = 1.00), runs, efficiency ===")
    print(f"{'Type':<16}" + "".join(f"{str(n) + 'N':>18}" for n in NODES))
    for itype, points in data.items():
        eff = efficiency(points)
        cells = []
        for n in NODES:
            if n in points:
                rel, runs = points[n]
                cells.append(f"{rel:6.2f} ({runs}r, {100 * eff[n]:3.0f}%)")
            else:
                cells.append("—")
        print(f"{itype:<16}" + "".join(f"{c:>18}" for c in cells))
