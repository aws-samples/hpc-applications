#!/usr/bin/env python3
"""
Generate the LS-DYNA charts of apps/LS-Dyna/Readme.md:
1. LSDYNA-Scaling.png: car2car-ver10 (R13.1), the CCSA Camry v5a and Yaris v2j
   (R17.0.1) on 1 to 4 nodes of hpc8a.96xlarge, hpc7a.96xlarge and hpc6a.48xlarge,
   every node fully populated, as relative performance against one hpc7a.96xlarge
   node of the same model (= 1.00, higher is faster). Each line's last point is
   labelled with its value and its parallel efficiency against the type's own first
   point. (3cars, measured on one node, is in the README's table only.)
2. LSDYNA-FlexibleCores.png: the same total rank count (192 or 384) spread over more,
   under-populated nodes at the flexible-cores counts, against the fully populated
   shape of the same total (= 1.00): speed, and EC2 cost per run (nodes x time).
3. LSDYNA-Versions.png: one model on one hpc8a.96xlarge (192 ranks) across LS-DYNA
   versions, against the same model on R13.1 (= 1.00).

Timing basis: LS-DYNA's own elapsed time ("Elapsed time ... seconds"), the deck's
full termination time. Per configuration the median over its runs is taken; relative
performance = the reference's median / the configuration's median. Only relative
values and run counts are embedded here.

Usage (from this directory):
    python3 generate_lsdyna_charts.py
"""
import matplotlib
matplotlib.use("Agg")  # write the PNGs without a display
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data. LS-DYNA MPP single precision with the cluster's Intel MPI 2021.18 over
# EFA (apps/LS-Dyna/LS-Dyna.sbatch's settings), one rank per core, the flexible-cores
# lists on under-populated hpc8a/hpc7a nodes; page cache dropped and THP set to always
# before each run; the decks as shipped (no lstc_reduce), with the documented changes
# (Camry: the mesh fix; 3cars: the region pfile and joint 27); AWS runs of October 2026
# in eu-north-1.
# ---------------------------------------------------------------------------
SCALING = {
    "car2car-ver10, R13.1": {
        "hpc8a.96xlarge": {1: (1.4064, 3), 2: (2.3014, 3), 4: (1.9383, 1)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.5179, 3), 4: (1.4261, 1)},
        "hpc6a.48xlarge": {1: (0.4754, 3), 2: (0.7779, 3), 4: (0.9627, 1)},
    },
    "Camry v5a, R17.0.1": {
        "hpc8a.96xlarge": {1: (1.4052, 3), 2: (2.5145, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.7522, 3)},
    },
    "Yaris v2j, R17.0.1": {
        "hpc8a.96xlarge": {1: (1.5222, 3), 2: (2.4593, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.5696, 3)},
    },
    "3cars, R17.0.1": {
        "hpc8a.96xlarge": {1: (1.5152, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3)},
    },
}
FLEX = {
    ("car2car-ver10, R13.1", "hpc8a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.4859, 1.3460, 3), (4, 48): (1.4908, 2.6831, 3)},
    ("car2car-ver10, R13.1", "hpc8a.96xlarge", 384): {(2, 192): (1.0000, 1.0000, 3), (4, 96): (0.9276, 2.1562, 3), (8, 48): (1.0712, 3.7340, 3)},
    ("car2car-ver10, R13.1", "hpc7a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.4474, 1.3818, 3), (4, 48): (1.4827, 2.6978, 3)},
    ("car2car-ver10, R13.1", "hpc7a.96xlarge", 384): {(2, 192): (1.0000, 1.0000, 3), (4, 96): (1.0629, 1.8817, 3), (8, 48): (1.1924, 3.3545, 3)},
    ("Camry v5a, R17.0.1", "hpc8a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.3925, 1.4362, 3), (4, 48): (1.5407, 2.5962, 3)},
    ("Camry v5a, R17.0.1", "hpc8a.96xlarge", 384): {(2, 192): (1.0000, 1.0000, 3), (4, 96): (1.2894, 1.5511, 3), (8, 48): (1.3328, 3.0013, 3)},
    ("Camry v5a, R17.0.1", "hpc7a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.3592, 1.4714, 3), (4, 48): (1.4481, 2.7623, 3)},
    ("Camry v5a, R17.0.1", "hpc7a.96xlarge", 384): {(2, 192): (1.0000, 1.0000, 3), (4, 96): (1.2729, 1.5712, 3), (8, 48): (1.2758, 3.1353, 3)},
    ("Yaris v2j, R17.0.1", "hpc8a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.3333, 1.5000, 3), (4, 48): (1.3740, 2.9113, 3)},
    ("Yaris v2j, R17.0.1", "hpc7a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.3199, 1.5152, 3), (4, 48): (1.3108, 3.0517, 3)},
    ("3cars, R17.0.1", "hpc8a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.2094, 1.6537, 3), (4, 48): (1.0548, 3.7922, 3)},
    ("3cars, R17.0.1", "hpc7a.96xlarge", 192): {(1, 192): (1.0000, 1.0000, 3), (2, 96): (1.0938, 1.8286, 3), (4, 48): (0.8772, 4.5600, 3)},
}
VERSIONS = {
    "car2car-ver10": [("R13.1", "LSTC AVX2", 1.0000, 3), ("R14.1.1", "Ansys SSE2", 0.8733, 3), ("R15.0.2", "LSTC AOCC AVX2", 1.0045, 3)],
    "Camry v5a": [("R13.1", "LSTC AVX2", 1.0000, 3), ("R14.1.1", "Ansys SSE2", 0.8172, 3), ("R16.1.1", "Ansys SSE2", 0.9425, 3), ("R16.2.1", "LSTC AOCC AVX-512", 1.0417, 3), ("R17.0.1", "LSTC AOCC AVX-512", 1.0395, 3)],
    "3cars": [("R13.1", "LSTC AVX2", 1.0000, 3), ("R14.1.1", "Ansys SSE2", 0.9361, 3), ("R16.1.1", "Ansys SSE2", 1.0540, 3), ("R16.2.1", "LSTC AOCC AVX-512", 1.1313, 3), ("R17.0.1", "LSTC AOCC AVX-512", 1.2684, 3)],
}
# SCALING: model -> per type {nodes: (relative performance, runs)}, full nodes, reference
# 1 x hpc7a.96xlarge of the same model. FLEX: (model, type, total ranks) -> {(nodes, ranks
# per node): (speed, EC2 cost per run, runs)} against the fully populated shape of that
# total (= 1.00, 1.00). VERSIONS: model -> [(version, build, relative performance, runs)]
# on one hpc8a.96xlarge at 192 ranks, against R13.1.

# type: (legend label, colour, marker)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 ranks/node)", "#232F3E", "o"),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s"),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P"),
}
NODES = [1, 2, 4]
DPI = 150


def efficiency(points):
    """Speed-up over the type's own first point, divided by the node-count ratio."""
    n0 = min(points)
    return {n: (rel / points[n0][0]) / (n / n0) for n, (rel, _) in points.items()}


def scaling_chart(output="LSDYNA-Scaling.png"):
    # Only the models measured on more than one node count have a line to draw.
    models = {m: spec for m, spec in SCALING.items() if any(len(p) > 1 for p in spec.values())}
    fig, axes = plt.subplots(1, len(models), figsize=(16, 5.8), sharey=True)
    for ax, (model, spec) in zip(axes, models.items()):
        for itype, (label, colour, marker) in STYLE.items():
            points = spec.get(itype)
            if not points:
                continue
            nodes = sorted(points)
            rel = [points[n][0] for n in nodes]
            ax.plot(nodes, rel, "-", color=colour, linewidth=2, label=label, zorder=2)
            for xv, yv in zip(nodes, rel):
                single = points[xv][1] == 1
                ax.plot([xv], [yv], marker=marker, markersize=7, color=colour, markeredgecolor=colour,
                        markeredgewidth=1.5, markerfacecolor="white" if single else colour, zorder=3)
            eff = efficiency(points)
            ax.annotate(f"{rel[-1]:.2f} ({100 * eff[nodes[-1]]:.0f}%)", (nodes[-1], rel[-1]),
                        xytext=(7, 0), textcoords="offset points", ha="left", va="center",
                        fontsize=8.5, fontweight="bold", color=colour)
        ax.annotate("= 1.00", (1, 1.0), xytext=(6, -11), textcoords="offset points", fontsize=8,
                    color=STYLE["hpc7a.96xlarge"][1])
        ax.set_xscale("log", base=2)
        ax.xaxis.set_major_locator(FixedLocator(NODES))
        ax.xaxis.set_minor_locator(NullLocator())
        ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
        ax.set_xlim(0.8, 6.5)
        ax.set_yscale("log", base=2)
        ax.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4]))
        ax.yaxis.set_minor_locator(NullLocator())
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
        ax.set_ylim(0.35, 4)
        ax.grid(True, which="major", linestyle="--", alpha=0.5)
        ax.set_title(f"{model}  (reference: 1 x hpc7a.96xlarge = 1.00)", fontsize=10.5)
        ax.set_xlabel("Number of nodes (every node fully populated)")
    axes[0].set_ylabel("Relative performance (higher is faster)")
    axes[0].legend(loc="upper left", fontsize=9)
    notes = [
        "LS-DYNA's own elapsed time to the deck's termination time. Median of 3 runs per point; hollow: a single run, "
        + "past the node count where the model stops scaling.",
        "Labels: the last point's value and its parallel efficiency against the type's own first point. Intel MPI 2021 "
        + "over EFA; AWS runs of October 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("LS-DYNA on hpc8a, hpc7a and hpc6a: scaling with full nodes", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.07, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


# model: marker; the instance type sets the colour (STYLE)
FLEX_MARKERS = {"car2car-ver10, R13.1": "o", "Camry v5a, R17.0.1": "s", "Yaris v2j, R17.0.1": "^",
                "3cars, R17.0.1": "D"}
# Where each panel names its shapes: (text, x, y) in data coordinates, above each cluster of markers
FLEX_SHAPE_LABELS = {
    192: [("2 x 96", 1.48, 1.54), ("4 x 48", 2.72, 1.585)],
    384: [("4 x 96", 1.56, 1.335), ("8 x 48", 3.07, 1.375)],
}


def flex_chart(output="LSDYNA-FlexibleCores.png"):
    """Speed against EC2 cost per run, each against the fully populated shape of the same total."""
    fig, axes = plt.subplots(1, 2, figsize=(15, 6.6), sharey=True)
    for ax, total in zip(axes, (192, 384)):
        ax.axhline(1.0, color="gray", linewidth=0.8, linestyle=":", zorder=1)
        ax.plot([1.0], [1.0], marker="*", markersize=16, color="gray", linestyle="none", zorder=4)
        full = "1 x 192" if total == 192 else "2 x 192"
        ax.annotate(f"{full} = 1.00", (1.0, 1.0), xytext=(0, -14), textcoords="offset points", fontsize=8.5,
                    color="dimgray", ha="left", va="top")
        for (model, itype, tot), shapes in FLEX.items():
            if tot != total:
                continue
            colour = STYLE[itype][1]
            pts = [(cost, speed) for (n, rpn), (speed, cost, _) in sorted(shapes.items()) if rpn != 192]
            ax.plot([1.0] + [p[0] for p in pts], [1.0] + [p[1] for p in pts], "-", color=colour, linewidth=1.0,
                    alpha=0.5, zorder=2)
            ax.plot([p[0] for p in pts], [p[1] for p in pts], marker=FLEX_MARKERS[model], markersize=8,
                    color=colour, linestyle="none", zorder=3, label=f"{model}, {itype}")
        for text, xv, yv in FLEX_SHAPE_LABELS[total]:
            ax.text(xv, yv, text, fontsize=10, fontweight="bold", color="dimgray", ha="center")
        ax.set_xlim(0.85, 4.8)
        ax.set_ylim(0.8, 1.7)
        ax.grid(True, linestyle="--", alpha=0.5)
        ax.set_xlabel(f"EC2 cost per run (nodes x time; {full} = 1.00)")
        ax.set_title(f"{total} ranks: {full} against more nodes at fewer ranks per node", fontsize=10.5)
        ax.legend(loc="upper right", fontsize=8)
    axes[0].set_ylabel("Speed (higher is faster; the fully populated shape = 1.00)")
    notes = [
        "Each line runs from the fully populated shape (star) to 2 x 96, then 4 x 48 (192 ranks), or to 4 x 96, then "
        + "8 x 48 (384 ranks): the same instance type and total ranks,",
        "more nodes at the flexible-cores counts per node. LS-DYNA's licence counts ranks, so with the same ranks its "
        + "cost per run follows the run time (1 / speed).",
        "Median of 3 runs per shape; LS-DYNA's own elapsed time; AWS runs of October 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=8.5, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("LS-DYNA: the same ranks spread over more nodes", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.09, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


VERSION_ORDER = ["R13.1", "R14.1.1", "R15.0.2", "R16.1.1", "R16.2.1", "R17.0.1"]
VERSION_COLOURS = {"R13.1": "#4E79A7", "R14.1.1": "#A0CBE8", "R15.0.2": "#59A14F", "R16.1.1": "#F28E2B",
                   "R16.2.1": "#E15759", "R17.0.1": "#76B7B2"}


def versions_chart(output="LSDYNA-Versions.png"):
    fig, ax = plt.subplots(figsize=(11, 5.8))
    width = 0.13
    builds = {}
    for g, (model, rows) in enumerate(VERSIONS.items()):
        start = g - width * (len(rows) - 1) / 2
        for i, (ver, build, rel, _) in enumerate(rows):
            xv = start + i * width
            ax.bar(xv, rel, width * 0.92, color=VERSION_COLOURS[ver], edgecolor="white", zorder=2)
            ax.text(xv, rel + 0.015, f"{rel:.2f}", ha="center", va="bottom", fontsize=8)
            builds.setdefault(ver, build)
    ax.axhline(1.0, color="gray", linewidth=0.8, linestyle=":", zorder=1)
    ax.set_xticks(range(len(VERSIONS)))
    ax.set_xticklabels(list(VERSIONS), fontsize=10)
    ax.set_ylim(0, 1.45)
    ax.set_ylabel("Relative performance (higher is faster; R13.1 = 1.00)")
    ax.grid(True, axis="y", linestyle="--", alpha=0.5)
    handles = [plt.Rectangle((0, 0), 1, 1, color=VERSION_COLOURS[v]) for v in VERSION_ORDER if v in builds]
    ax.legend(handles, [f"{v} ({builds[v]})" for v in VERSION_ORDER if v in builds], loc="upper left", fontsize=8.5,
              ncol=3)
    notes = [
        "One hpc8a.96xlarge, 192 ranks; LS-DYNA's own elapsed time; median of 3 runs per bar; AWS runs of October 2026. "
        + "Each bar is one version's build (legend),",
        "so it holds the build's compiler and instruction set as well as the version. The Camry runs with its mesh fix "
        + "on every version, 3cars with its region pfile and joint 27.",
        "Of the versions checked, car2car-ver10 runs on R12.2.2, R13.1, R14.1.1 and R15.0.2; the Camry and 3cars were "
        + "not run on R15.0.2.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=8.5, style="italic", color="dimgray", ha="left", va="bottom")
    ax.set_title("LS-DYNA versions on one hpc8a.96xlarge: each model against its R13.1 run",
                 fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.1, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


scaling_chart()
flex_chart()
versions_chart()

# ---------------------------------------------------------------------------
# Also print summary tables for reference (the README's tables)
# ---------------------------------------------------------------------------
print("\n=== Relative performance (1 x hpc7a.96xlarge = 1.00), runs, parallel efficiency ===")
for model, spec in SCALING.items():
    print(f"-- {model}")
    for itype in STYLE:
        points = spec.get(itype)
        if not points:
            continue
        eff = efficiency(points)
        print(f"   {itype:<16}" + "".join(f"{n:>3}N {rel:6.2f} ({runs}r, {100 * eff[n]:3.0f}%)"
                                         for n, (rel, runs) in sorted(points.items())))
print("\n=== Same total ranks on more nodes (fully populated shape = 1.00): speed, EC2 cost per run ===")
for (model, itype, total), shapes in FLEX.items():
    print(f"-- {model}, {itype}, {total} ranks: "
          + "; ".join(f"{n} x {rpn}: {s:.2f}, {c:.2f} ({r}r)" for (n, rpn), (s, c, r) in sorted(shapes.items())))
print("\n=== Versions on one hpc8a.96xlarge, 192 ranks (R13.1 = 1.00) ===")
for model, rows in VERSIONS.items():
    print(f"-- {model}: " + "; ".join(f"{v} ({b}): {rel:.2f} ({r}r)" for v, b, rel, r in rows))
