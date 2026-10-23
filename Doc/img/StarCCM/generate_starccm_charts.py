#!/usr/bin/env python3
"""
Generate the STAR-CCM+ 2606 charts of apps/StarCCM/Readme.md:

1. STARCCM-2606-Scaling.png: six models of Siemens's benchmark suite on 1 to 16
   nodes of hpc8a.96xlarge, hpc7a.96xlarge and hpc6a.48xlarge, every node fully
   populated, as relative performance against one hpc7a.96xlarge node of the same
   model (= 1.00, higher is faster). AeroSUV 322M needs at least two nodes: its
   reference is two hpc7a.96xlarge nodes. Each line's last point is labelled with
   its value and its parallel efficiency against the type's own first point.
2. STARCCM-2606-FlexibleCores.png: AeroSUV 106M and LeMans 100M with the same total
   rank count spread over more, under-populated nodes (the flexible-cores counts),
   against the fully populated shape of the same total (= 1.00): speed, and EC2
   cost per run (nodes x time).

Timing basis: STAR-CCM+'s own -benchmark mode with Siemens's protocol for each
model (pre-iterations, 20 timed iterations, -preclear where Siemens asks for it;
civil with 120 pre-iterations), the AverageElapsedTime of the timed iterations.
Per configuration the median over its runs is taken; relative performance = the
reference's median / the configuration's median. Only relative values and run
counts are embedded here.

Usage (from this directory):
    python3 generate_starccm_charts.py
"""

import matplotlib

matplotlib.use("Agg")  # write the PNGs without a display

import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data. STAR-CCM+ 2606 (21.04.007) mixed precision, Open MPI 5.0.9 (bundled)
# over EFA with the 21.02 x86 scripts' options (-xsystemlibfabric -ldlibpath
# /opt/amazon/efa/lib64 -fabric OFI, default -cpubind bandwidth), page cache dropped
# and THP set to always before each run; AWS runs of October 2026 in eu-north-1.
# ---------------------------------------------------------------------------
SCALING = {
    # model: reference, then per type {nodes: (relative performance, runs)}, full nodes
    "reactor": {"reference": (1, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {1: (1.4325, 3), 2: (2.9243, 3), 4: (5.7071, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (2.0425, 3), 4: (3.8776, 3)},
        "hpc6a.48xlarge": {1: (0.3741, 3), 2: (0.7972, 3), 4: (1.6632, 3), 8: (3.1287, 3)},
    },
    "civil (120 pre-iterations)": {"reference": (1, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {1: (1.4218, 3), 2: (2.9105, 3), 4: (5.8503, 3), 8: (10.9242, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (2.0713, 3), 4: (4.0333, 3), 8: (7.7826, 3)},
        "hpc6a.48xlarge": {1: (0.4031, 3), 2: (0.8097, 3), 4: (1.7026, 3), 8: (3.4838, 3), 16: (6.3623, 3)},
    },
    "LeMans 100M segregated": {"reference": (1, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {1: (1.3874, 3), 2: (2.8591, 3), 4: (5.7336, 3), 8: (11.9537, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (2.0152, 3), 4: (3.9456, 3), 8: (7.9942, 3)},
        "hpc6a.48xlarge": {1: (0.3674, 3), 2: (0.7670, 3), 4: (1.5633, 3), 8: (3.1231, 3), 16: (6.4110, 3)},
    },
    "AeroSUV 106M coupled": {"reference": (1, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {1: (1.4154, 3), 2: (2.8082, 3), 4: (5.8242, 3), 8: (11.4251, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.9740, 3), 4: (4.0236, 3), 8: (7.7236, 3)},
        "hpc6a.48xlarge": {1: (0.3956, 3), 2: (0.7649, 3), 4: (1.5955, 3), 8: (3.3063, 3), 16: (5.9692, 3)},
    },
    "vtmBenchmark 178M": {"reference": (1, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {1: (1.3730, 3), 2: (2.7462, 3), 4: (5.3503, 3), 8: (9.7015, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.9941, 3), 4: (3.8083, 3), 8: (6.5665, 3)},
        "hpc6a.48xlarge": {1: (0.3878, 3), 2: (0.7038, 3), 4: (1.5475, 3), 8: (3.0347, 3), 16: (5.4989, 3)},
    },
    "AeroSUV 322M coupled": {"reference": (2, "hpc7a.96xlarge"),
        "hpc8a.96xlarge": {2: (1.4111, 3), 4: (2.8427, 3), 8: (5.5767, 3)},
        "hpc7a.96xlarge": {2: (1.0000, 3), 4: (2.0068, 3), 8: (3.8719, 3)},
        "hpc6a.48xlarge": {4: (0.8103, 3), 8: (1.5894, 3), 16: (3.2140, 3)},
    },
}

# The same total ranks on more, under-populated nodes: per (model, type, total ranks),
# {(nodes, ranks per node): (speed, EC2 cost per run, runs)} against the fully populated
# shape of that total (= 1.00, 1.00).
FLEX = {
    ("AeroSUV 106M coupled", "hpc8a.96xlarge", 384): {
        (2, 192): (1.0000, 1.0000, 3), (4, 96): (1.8308, 1.0924, 3), (8, 48): (2.4190, 1.6536, 3)},
    ("AeroSUV 106M coupled", "hpc7a.96xlarge", 384): {
        (2, 192): (1.0000, 1.0000, 3), (4, 96): (1.8511, 1.0804, 3), (8, 48): (2.3901, 1.6736, 3)},
    ("LeMans 100M segregated", "hpc8a.96xlarge", 384): {
        (2, 192): (1.0000, 1.0000, 3), (4, 96): (1.6929, 1.1814, 3), (8, 48): (2.1917, 1.8251, 3)},
    ("LeMans 100M segregated", "hpc7a.96xlarge", 384): {
        (2, 192): (1.0000, 1.0000, 3), (4, 96): (1.7084, 1.1707, 3), (8, 48): (2.1454, 1.8645, 3)},
    ("AeroSUV 106M coupled", "hpc8a.96xlarge", 576): {
        (3, 192): (1.0000, 1.0000, 3), (4, 144): (1.2747, 1.0460, 3), (6, 96): (1.7246, 1.1597, 3)},
}

# Fewer ranks on one node (AeroSUV 106M coupled): per type {ranks per node: (speed, ranks x time, runs)}
# against the fully populated node (192 ranks = 1.00, 1.00). Printed for the README's table, not charted.
ONE_NODE = {
    "hpc8a.96xlarge": {192: (1.0000, 1.0000, 3), 144: (0.9836, 0.7625, 3), 96: (0.9113, 0.5487, 3)},
    "hpc7a.96xlarge": {192: (1.0000, 1.0000, 3), 144: (0.9723, 0.7714, 3), 96: (0.9820, 0.5091, 3)},
}

# type: (legend label, colour, marker)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 ranks/node)", "#232F3E", "o"),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s"),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P"),
}
NODES = [1, 2, 4, 8, 16]
DPI = 150


def efficiency(points):
    """Speed-up over the type's own first point, divided by the node-count ratio."""
    n0 = min(points)
    return {n: (rel / points[n0][0]) / (n / n0) for n, (rel, _) in points.items()}


def node_axis(ax):
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(NODES))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.set_xlim(0.8, 30)
    ax.grid(True, which="major", linestyle="--", alpha=0.5)


def scaling_chart(output="STARCCM-2606-Scaling.png"):
    fig, axes = plt.subplots(2, 3, figsize=(16, 9.6), sharex=True)
    for ax, (model, spec) in zip(axes.flat, SCALING.items()):
        ref_nodes, ref_type = spec["reference"]
        for itype, (label, colour, marker) in STYLE.items():
            points = spec.get(itype)
            if not points:
                continue
            nodes = sorted(points)
            rel = [points[n][0] for n in nodes]
            ax.plot(nodes, rel, "-", color=colour, linewidth=2, label=label, zorder=2)
            for x, y in zip(nodes, rel):
                single = points[x][1] == 1
                ax.plot([x], [y], marker=marker, markersize=7, color=colour, markeredgecolor=colour,
                        markeredgewidth=1.5, markerfacecolor="white" if single else colour, zorder=3)
            eff = efficiency(points)
            ax.annotate(f"{rel[-1]:.2f} ({100 * eff[nodes[-1]]:.0f}%)", (nodes[-1], rel[-1]),
                        xytext=(7, 0), textcoords="offset points", ha="left", va="center",
                        fontsize=8.5, fontweight="bold", color=colour)
        ax.annotate("= 1.00", (ref_nodes, 1.0), xytext=(6, -11), textcoords="offset points",
                    fontsize=8, color=STYLE[ref_type][1])
        node_axis(ax)
        ax.set_yscale("log", base=2)
        ax.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4, 8, 16]))
        ax.yaxis.set_minor_locator(NullLocator())
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
        ax.set_ylim(0.25, 20)
        ref_text = "1 x hpc7a.96xlarge" if ref_nodes == 1 else f"{ref_nodes} x hpc7a.96xlarge"
        ax.set_title(f"{model}  (reference: {ref_text} = 1.00)", fontsize=10.5)
    for ax in axes[1]:
        ax.set_xlabel("Number of nodes (every node fully populated)")
    for ax in axes[:, 0]:
        ax.set_ylabel("Relative performance (higher is faster)")
    axes[0, 0].legend(loc="upper left", fontsize=9)
    runs = sorted({r for spec in SCALING.values() for itype, pts in spec.items() if itype != "reference"
                   for _, r in pts.values()})
    notes = [
        "Each model timed with STAR-CCM+'s -benchmark mode and Siemens's protocol for it (AverageElapsedTime of "
        "the 20 timed iterations); civil with 120 pre-iterations.",
        f"Median of {' or '.join(str(r) for r in runs)} runs per point. Labels: the last point's value and its "
        "parallel efficiency against the type's own first point. Open MPI 5.0.9 over EFA; AWS runs of October 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("STAR-CCM+ 2606 on six Siemens benchmark models: scaling on hpc8a, hpc7a and hpc6a",
                 fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.05, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


# (model, total ranks): marker; the instance type sets the colour (STYLE)
FLEX_MARKERS = {("AeroSUV 106M coupled", 384): "o", ("LeMans 100M segregated", 384): "s",
                ("AeroSUV 106M coupled", 576): "^"}
# Label offsets in points where the default (right of the marker) would collide
FLEX_LABEL_OFFSETS = {
    ("AeroSUV 106M coupled", "hpc8a.96xlarge", 384, 8, 48): (-9, 4),
    ("AeroSUV 106M coupled", "hpc7a.96xlarge", 384, 4, 96): (-9, 4),
}
# Three markers nearly coincide (AeroSUV 106M at 6 x 96, and LeMans 100M at 4 x 96 on both types): their
# labels sit clear of the cluster at fixed offsets, each joined to its marker by a short line in its colour.
FLEX_LEADER_OFFSETS = {
    ("AeroSUV 106M coupled", "hpc8a.96xlarge", 576, 6, 96): (-24, 3),
    ("LeMans 100M segregated", "hpc7a.96xlarge", 384, 4, 96): (18, 28),
    ("LeMans 100M segregated", "hpc8a.96xlarge", 384, 4, 96): (24, -16),
}


def flex_chart(output="STARCCM-2606-FlexibleCores.png"):
    """Speed against EC2 cost per run, each against the fully populated shape of the same total."""
    fig, ax = plt.subplots(figsize=(10.5, 7))
    ax.plot([1.0], [1.0], marker="*", markersize=16, color="gray", linestyle="none", zorder=4)
    ax.annotate("fully populated shape of the same total = 1.00\n(2 x 192 for 384 ranks, 3 x 192 for 576)",
                (1.0, 1.0), xytext=(14, 2), textcoords="offset points", fontsize=8.5, color="dimgray",
                va="bottom")
    for (model, itype, total), shapes in FLEX.items():
        colour = STYLE[itype][1]
        marker = FLEX_MARKERS[(model, total)]
        pts = [(cost, speed, n, rpn) for (n, rpn), (speed, cost, _) in sorted(shapes.items()) if rpn != 192]
        ax.plot([1.0] + [p[0] for p in pts], [1.0] + [p[1] for p in pts], "-", color=colour, linewidth=1.2,
                alpha=0.6, zorder=2)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], marker=marker, markersize=9, color=colour,
                linestyle="none", zorder=3, label=f"{model}, {total} ranks, {itype}")
        for cost, speed, n, rpn in pts:
            key = (model, itype, total, n, rpn)
            if key in FLEX_LEADER_OFFSETS:
                offset = FLEX_LEADER_OFFSETS[key]
                ax.annotate(f"{n} x {rpn}", (cost, speed), xytext=offset, textcoords="offset points",
                            fontsize=8.5, color=colour, ha="right" if offset[0] < 0 else "left", va="center",
                            arrowprops={"arrowstyle": "-", "lw": 0.6, "color": colour, "shrinkB": 4})
                continue
            offset = FLEX_LABEL_OFFSETS.get(key, (8, -4))
            ax.annotate(f"{n} x {rpn}", (cost, speed), xytext=offset, textcoords="offset points",
                        fontsize=8.5, color=colour, ha="right" if offset[0] < 0 else "left")
    ax.set_xlabel("EC2 cost per run (nodes x time; fully populated shape = 1.00)")
    ax.set_ylabel("Speed (higher is faster; fully populated shape = 1.00)")
    ax.set_xlim(0.9, 2.05)
    ax.set_ylim(0.9, 2.65)
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.legend(loc="lower right", fontsize=8.5)
    notes = [
        "Same instance type and total ranks, more nodes at the flexible-cores counts per node (96 or 48 ranks; 144 "
        "for 4 x 144). With the same ranks, a licence per core",
        "(cost per rank-hour) and a Power licence (cost per run-hour, any core count) both cost in proportion to the "
        "run time. Median of 3 runs per shape; AWS runs of October 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=8.5, style="italic", color="dimgray", ha="left", va="bottom")
    ax.set_title("STAR-CCM+ 2606: the same ranks spread over more nodes", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.06, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


scaling_chart()
flex_chart()

# ---------------------------------------------------------------------------
# Also print summary tables for reference (the README's tables)
# ---------------------------------------------------------------------------
print("\n=== Relative performance (reference = 1.00), runs, parallel efficiency ===")
for model, spec in SCALING.items():
    print(f"-- {model} (reference {spec['reference'][0]} x {spec['reference'][1]})")
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
print("\n=== AeroSUV 106M coupled on one node (192 ranks = 1.00): speed, ranks x time ===")
for itype, counts in ONE_NODE.items():
    print(f"-- {itype}: " + "; ".join(f"{rpn} ranks: {s:.2f}, {rt:.2f} ({r}r)"
                                      for rpn, (s, rt, r) in sorted(counts.items(), reverse=True)))
