#!/usr/bin/env python3
"""
Generate the Ansys Fluent charts of apps/Fluent/Readme.md:
1. Fluent-f1_racecar_140m-Scaling.png: f1_racecar_140m on 1 to 16 fully populated
   nodes of hpc8a.96xlarge and hpc7a.96xlarge, as relative performance against one
   hpc7a.96xlarge node (= 1.00, higher is faster), next to the EC2 cost per run
   against one node of the same type (nodes x time, = 1.00). Each line's last point
   is labelled with its parallel efficiency against the type's own single node.
2. Fluent-f1_racecar_140m-FlexibleCores.png: f1_racecar_140m with the same total
   rank count spread over more nodes at 96, 48 or 24 ranks per node (flexible-cores
   counts), against the fully populated shape of the same total (= 1.00): speed, and
   EC2 cost per run (nodes x time). The right axis reads the speed as licence
   core-hours per run (cores x time = 1 / speed, at the same total cores).
3. Fluent-InstanceTypes-192cores-AMD.png and Fluent-InstanceTypes-192cores-Intel.png:
   four smaller cases of the Ansys Fluent benchmark suite on 192 cores (one node of
   the 192-core types, two of the 96-core types), one chart per CPU vendor, each
   against one node of a type of the same vendor (= 1.00): three AMD types against
   hpc7a.96xlarge, five Intel types against c8i.96xlarge. Speed, and EC2 cost per run
   (nodes x time x the type's On-Demand price).
Timing basis: Fluent's solver wall time per iteration (fluentbench.pl, charts 1 and
2) and the 2026 R1 benchmark harness's MIUPS (million cell iterations per wall
second, the two charts of 3). Per configuration the median over its runs is taken;
relative performance = the reference's median time / the configuration's median
time. Only relative values and run counts are embedded here.
Usage (from this directory):
    python3 generate_fluent_charts.py
"""
import matplotlib

matplotlib.use("Agg")  # write the PNGs without a display
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data, f1_racecar_140m (charts 1 and 2): Fluent 2026 R1 (v261) with the
# classic fluentbench.pl harness (25 iterations), -platform=intel, Intel MPI 2021.16
# over EFA; page cache dropped and THP set to always before each run; AWS runs of
# March 2026 in us-east-2.
# ---------------------------------------------------------------------------
# type: {nodes: (relative performance against 1 x hpc7a.96xlarge, runs)}, 192 ranks per node
# (5 decimals, so that every parallel efficiency printed below rounds as from the medians)
SCALING = {
    "hpc8a.96xlarge": {1: (1.48441, 5), 2: (2.94802, 5), 4: (5.76114, 4), 8: (10.87210, 4), 16: (20.54141, 4)},
    "hpc7a.96xlarge": {1: (1.00000, 4), 2: (1.97001, 4), 4: (3.82683, 4), 8: (7.20642, 4), 16: (13.07989, 4)},
}
# (type, total ranks): {(nodes, ranks per node): (speed, EC2 cost per run, runs)} against
# the fully populated shape of that total (= 1.00, 1.00)
FLEX = {
    ("hpc8a.96xlarge", 192): {(2, 96): (1.5114, 1.3233, 4), (4, 48): (1.7859, 2.2397, 4),
                              (8, 24): (1.8707, 4.2766, 4)},
    ("hpc8a.96xlarge", 384): {(4, 96): (1.4883, 1.3438, 4), (8, 48): (1.7746, 2.2540, 4),
                              (16, 24): (1.8528, 4.3179, 4)},
    ("hpc8a.96xlarge", 768): {(8, 96): (1.5004, 1.3330, 4), (16, 48): (1.7724, 2.2569, 4)},
    ("hpc8a.96xlarge", 1536): {(16, 96): (1.5455, 1.2941, 4)},
    ("hpc7a.96xlarge", 192): {(2, 96): (1.6151, 1.2383, 4), (4, 48): (1.8738, 2.1347, 4),
                              (8, 24): (1.9476, 4.1076, 4)},
    ("hpc7a.96xlarge", 384): {(4, 96): (1.6004, 1.2497, 4), (8, 48): (1.8247, 2.1922, 4),
                              (16, 24): (1.9207, 4.1653, 4)},
    ("hpc7a.96xlarge", 768): {(8, 96): (1.6104, 1.2419, 4), (16, 48): (1.8428, 2.1706, 4)},
    ("hpc7a.96xlarge", 1536): {(16, 96): (1.6430, 1.2173, 4)},
}

# ---------------------------------------------------------------------------
# Measured data, four smaller cases of the suite (the two charts of 3): Fluent 2026
# R1 (v261) with the 2026 R1 benchmark harness (CPU solver, two warm-up blocks of
# 10, then 25 timed iterations, time steps for the transient landing_gear_15m and
# lm6000_16m), -platform=intel, Intel MPI 2021.18 over EFA; page cache dropped and
# THP set to always before each run (SMT off on the Intel types); AWS runs of
# August 2026 in eu-north-1. EC2 cost per run: nodes x time x the On-Demand Linux
# price in eu-north-1 (October 2026). One chart per CPU vendor, each against one
# node of the vendor's reference type.
# ---------------------------------------------------------------------------
CASES = ["sedan_4m", "aircraft_wing_14m", "landing_gear_15m", "lm6000_16m"]
# CPU vendor: the reference type of its chart (one node = 1.00, 1.00)
REFERENCE = {"AMD": "hpc7a.96xlarge", "Intel": "c8i.96xlarge"}
# CPU vendor: {type: (nodes, cores per node)} for 192 cores, in the chart's order
LAYOUT = {
    "AMD": {"hpc8a.96xlarge": (1, 192), "hpc7a.96xlarge": (1, 192), "hpc6a.48xlarge": (2, 96)},
    "Intel": {"c8i.96xlarge": (1, 192), "r8i.96xlarge": (1, 192), "m7i.48xlarge": (2, 96),
              "r7i.48xlarge": (2, 96), "c7i.48xlarge": (2, 96)},
}
# CPU vendor: {type: {case: (speed, EC2 cost per run, runs)}} against one node of the
# vendor's reference type (= 1.00, 1.00)
INSTANCES = {
    "AMD": {
        "hpc8a.96xlarge": {"sedan_4m": (1.4881, 0.7392, 3), "aircraft_wing_14m": (1.5323, 0.7179, 3),
                           "landing_gear_15m": (1.5413, 0.7137, 3), "lm6000_16m": (1.6708, 0.6584, 3)},
        "hpc7a.96xlarge": {"sedan_4m": (1.0000, 1.0000, 3), "aircraft_wing_14m": (1.0000, 1.0000, 3),
                           "landing_gear_15m": (1.0000, 1.0000, 3), "lm6000_16m": (1.0000, 1.0000, 3)},
        "hpc6a.48xlarge": {"sedan_4m": (0.8420, 0.9511, 3), "aircraft_wing_14m": (0.8667, 0.9239, 4),
                           "landing_gear_15m": (0.8817, 0.9081, 3), "lm6000_16m": (1.0098, 0.7929, 3)},
    },
    "Intel": {
        "c8i.96xlarge": {"sedan_4m": (1.0000, 1.0000, 3), "aircraft_wing_14m": (1.0000, 1.0000, 3),
                         "landing_gear_15m": (1.0000, 1.0000, 3), "lm6000_16m": (1.0000, 1.0000, 3)},
        "r8i.96xlarge": {"sedan_4m": (0.9512, 1.5481, 3), "aircraft_wing_14m": (0.9760, 1.5087, 3),
                         "landing_gear_15m": (0.9792, 1.5038, 3), "lm6000_16m": (0.9851, 1.4948, 3)},
        "m7i.48xlarge": {"sedan_4m": (0.7593, 1.4059, 3), "aircraft_wing_14m": (0.8039, 1.3278, 3),
                         "landing_gear_15m": (0.7905, 1.3504, 3), "lm6000_16m": (0.7929, 1.3462, 3)},
        "r7i.48xlarge": {"sedan_4m": (0.7452, 1.8818, 3), "aircraft_wing_14m": (0.8023, 1.7480, 3),
                         "landing_gear_15m": (0.8046, 1.7429, 3), "lm6000_16m": (0.8360, 1.6776, 3)},
        "c7i.48xlarge": {"sedan_4m": (0.7078, 1.3455, 3), "aircraft_wing_14m": (0.7467, 1.2754, 3),
                         "landing_gear_15m": (0.7760, 1.2273, 3), "lm6000_16m": (0.8172, 1.1654, 3)},
    },
}
# CPU vendor: chart height (inches), and the speed and cost axes' upper limits
INSTANCE_CHART = {"AMD": (4.9, 1.85, 1.3), "Intel": (6.2, 1.15, 2.1)}

# type: (legend label, colour, marker)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 cores/node)", "#232F3E", "o"),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s"),
}
CASE_COLOURS = {"sedan_4m": "#4E79A7", "aircraft_wing_14m": "#59A14F", "landing_gear_15m": "#B07AA1",
                "lm6000_16m": "#E15759"}
# vertical offset in points of the last point's label on the cost panel (the two lines end close
# together), and the height (axes fraction) of each type's speed-up line in the panel's empty lower half
LABEL_DY = {"hpc8a.96xlarge": -4, "hpc7a.96xlarge": 4}
SPEEDUP_Y = {"hpc8a.96xlarge": 0.40, "hpc7a.96xlarge": 0.34}
NODES = [1, 2, 4, 8, 16]
DPI = 150
NUMBER_WORDS = {3: "three", 5: "five"}


def efficiency(points):
    """Speed-up over the type's own single node, divided by the node count."""
    one = points[1][0]
    return {n: rel / one / n for n, (rel, _) in points.items()}


def node_axis(ax):
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(NODES))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.set_xlim(0.85, 24)
    ax.set_xlabel("Number of nodes (192 ranks per node)")
    ax.grid(True, which="major", linestyle="--", alpha=0.5)


def run_counts(values):
    """'4 or 5' from the run counts of a data block."""
    runs = sorted(set(values))
    return runs[0] if len(runs) == 1 else " or ".join(str(r) for r in runs)


def scaling_chart(output="Fluent-f1_racecar_140m-Scaling.png"):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 6.6))
    for itype, points in SCALING.items():
        label, colour, marker = STYLE[itype]
        nodes = sorted(points)
        rel = [points[n][0] for n in nodes]
        eff = efficiency(points)
        cost = [1 / eff[n] for n in nodes]  # nodes x time over 1 node x its time
        ax1.plot(nodes, rel, "-", color=colour, linewidth=2, marker=marker, markersize=8, label=label, zorder=3)
        ax1.annotate(f"{rel[-1]:.2f} ({100 * eff[nodes[-1]]:.0f}%)", (nodes[-1], rel[-1]), xytext=(7, 0),
                     textcoords="offset points", ha="left", va="center", fontsize=9.5, fontweight="bold",
                     color=colour)
        ax2.plot(nodes, cost, "-", color=colour, linewidth=2, marker=marker, markersize=8, label=label, zorder=3)
        ax2.annotate(f"{cost[-1]:.2f}", (nodes[-1], cost[-1]), xytext=(7, LABEL_DY[itype]),
                     textcoords="offset points", ha="left", va="center", fontsize=9.5, fontweight="bold",
                     color=colour)
        speedup = eff[nodes[-1]] * nodes[-1]
        ax2.text(0.97, SPEEDUP_Y[itype], f"{itype} on {nodes[-1]} nodes: {speedup:.1f}x as fast as on 1 node, "
                 + f"for {cost[-1]:.2f}x the EC2 cost per run", transform=ax2.transAxes, ha="right", va="center",
                 fontsize=9.5, color=colour)
    ax1.annotate("= 1.00", (1, 1.0), xytext=(6, -12), textcoords="offset points", fontsize=8.5,
                 color=STYLE["hpc7a.96xlarge"][1])
    node_axis(ax1)
    ax1.set_yscale("log", base=2)
    ax1.yaxis.set_major_locator(FixedLocator([1, 2, 4, 8, 16, 32]))
    ax1.yaxis.set_minor_locator(NullLocator())
    ax1.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax1.set_ylim(0.8, 32)
    ax1.set_ylabel("Relative performance (1 x hpc7a.96xlarge = 1.00, higher is faster)")
    ax1.set_title("Relative performance (label: parallel efficiency against 1 node)", fontsize=11)
    ax1.legend(loc="upper left", fontsize=9.5)
    node_axis(ax2)
    ax2.axhline(1.0, color="gray", linestyle=":", linewidth=1.2, zorder=1)
    ax2.set_ylim(0, 1.5)
    ax2.set_ylabel("EC2 cost per run (1 node of the same type = 1.00)")
    ax2.set_title("EC2 cost per run: nodes x time against 1 node of the same type", fontsize=11)
    ax2.legend(loc="lower left", fontsize=9.5)
    runs = run_counts([r for points in SCALING.values() for _, r in points.values()])
    notes = [
        "f1_racecar_140m (about 140 million cells), Fluent 2026 R1, fluentbench.pl (solver wall time per "
        + "iteration), IntelMPI over EFA; every node fully populated.",
        f"Median of {runs} runs per point; AWS runs of March 2026. With licences counted per core, the licence "
        + "core-hours per run (cores x time) follow the same ratio as the EC2 cost per run.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("Ansys Fluent f1_racecar_140m on hpc8a and hpc7a: scaling, and the EC2 cost per run",
                 fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.06, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


# total ranks: marker; the instance type sets the colour (STYLE). Markers are hollow, so
# that shapes of different totals stay visible where their values nearly coincide.
FLEX_MARKERS = {192: "o", 384: "s", 768: "^", 1536: "D"}
# one label per ranks-per-node cluster: (text, (x, y) in data units, horizontal alignment)
CLUSTER_LABELS = {
    96: ("2x the nodes,\n96 ranks per node", (1.42, 1.36), "left"),
    48: ("4x the nodes,\n48 ranks per node", (2.22, 1.64), "center"),
    24: ("8x the nodes,\n24 ranks per node", (4.21, 1.74), "center"),
}


def flex_chart(output="Fluent-f1_racecar_140m-FlexibleCores.png"):
    """Speed against EC2 cost per run, each against the fully populated shape of the same total."""
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.plot([1.0], [1.0], marker="*", markersize=16, color="gray", linestyle="none", zorder=4)
    ax.annotate("fully populated shape of the same total = 1.00\n(1 x 192 for 192 ranks, 2 x 192 for 384, ...)",
                (1.0, 1.0), xytext=(12, 0), textcoords="offset points", fontsize=8.5, color="dimgray",
                va="center")
    for (itype, total), shapes in FLEX.items():
        colour = STYLE[itype][1]
        pts = sorted(shapes.items(), key=lambda kv: kv[1][1])  # by cost
        ax.plot([1.0] + [p[1][1] for p in pts], [1.0] + [p[1][0] for p in pts], "-", color=colour, linewidth=1,
                alpha=0.45, zorder=2)
        ax.plot([p[1][1] for p in pts], [p[1][0] for p in pts], marker=FLEX_MARKERS[total], markersize=9,
                markerfacecolor="none", markeredgecolor=colour, markeredgewidth=1.8, linestyle="none", zorder=3)
    for rpn, (text, xy, ha) in CLUSTER_LABELS.items():
        ax.annotate(text, xy, fontsize=9, color="black", ha=ha, va="center")
    # legend: colours for the types, markers for the totals
    for itype in SCALING:
        ax.plot([], [], "-", color=STYLE[itype][1], linewidth=6, label=itype)
    for total, marker in FLEX_MARKERS.items():
        ax.plot([], [], marker=marker, markerfacecolor="none", markeredgecolor="gray", markeredgewidth=1.8,
                linestyle="none", markersize=9, label=f"{total} ranks")
    ax.set_xlabel("EC2 cost per run (nodes x time; fully populated shape = 1.00)")
    ax.set_ylabel("Speed (higher is faster; fully populated shape = 1.00)")
    ax.set_xlim(0.8, 4.6)
    ax.set_ylim(0.9, 2.1)
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.legend(loc="lower right", fontsize=9, ncol=2)
    # cores x time = 1 / speed at the same total cores (clipped: the axis transform also sees 0)
    licence = ax.secondary_yaxis("right", functions=(lambda s: 1 / np.clip(s, 1e-6, None),
                                                     lambda lic: 1 / np.clip(lic, 1e-6, None)))
    licence.yaxis.set_major_locator(FixedLocator([1.0, 0.9, 0.8, 0.7, 0.6, 0.5]))
    licence.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.2f}"))
    licence.set_ylabel("Licence core-hours per run (cores x time = 1 / speed)")
    # each value is a ratio to the fully populated shape of the same total, so its runs count too
    runs = run_counts([r for shapes in FLEX.values() for _, _, r in shapes.values()]
                      + [SCALING[itype][total // 192][1] for itype, total in FLEX])
    notes = [
        "f1_racecar_140m, Fluent 2026 R1, fluentbench.pl, IntelMPI over EFA; the same instance type and total "
        + "ranks on more nodes, at the flexible-cores",
        f"counts per node. Median of {runs} runs per shape; AWS runs of March 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=8.5, style="italic", color="dimgray", ha="left", va="bottom")
    ax.set_title("Ansys Fluent f1_racecar_140m: the same ranks spread over more nodes", fontsize=13,
                 fontweight="bold")
    plt.tight_layout(rect=(0, 0.05, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


def instances_chart(vendor):
    """Speed and EC2 cost per run of one CPU vendor's instance types on 192 cores, against one node
    of the vendor's reference type."""
    output = f"Fluent-InstanceTypes-192cores-{vendor}.png"
    data, layout, reference = INSTANCES[vendor], LAYOUT[vendor], REFERENCE[vendor]
    height_in, speed_max, cost_max = INSTANCE_CHART[vendor]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, height_in), sharey=True)
    types = list(data)
    height = 0.19
    for i, case in enumerate(CASES):
        offset = ((len(CASES) - 1) / 2 - i) * height  # the first case on top, as in the legend
        ys = [len(types) - 1 - k + offset for k in range(len(types))]
        ax1.barh(ys, [data[t][case][0] for t in types], height=height, color=CASE_COLOURS[case],
                 label=case, zorder=3)
        ax2.barh(ys, [data[t][case][1] for t in types], height=height, color=CASE_COLOURS[case],
                 label=case, zorder=3)
    labels = [f"{t}\n({layout[t][0]} x {layout[t][1]} cores)" for t in types]
    ax1.set_yticks(range(len(types)))
    ax1.set_yticklabels(labels[::-1], fontsize=9.5)
    for ax, title, xlabel in (
            (ax1, "Speed", f"Relative performance (1 x {reference} = 1.00, higher is faster)"),
            (ax2, "EC2 cost per run", f"EC2 cost per run (1 x {reference} = 1.00, lower is cheaper)")):
        ax.axvline(1.0, color="gray", linestyle=":", linewidth=1.2, zorder=2)
        ax.grid(True, axis="x", linestyle="--", alpha=0.5, zorder=0)
        ax.set_title(title, fontsize=11)
        ax.set_xlabel(xlabel)
    ax1.set_xlim(0, speed_max)
    ax2.set_xlim(0, cost_max)
    # one legend for both panels, in a row under the title (inches from the top, whatever the height)
    handles, case_labels = ax2.get_legend_handles_labels()
    fig.legend(handles, case_labels, loc="upper center", bbox_to_anchor=(0.5, 1 - 0.36 / height_in),
               ncol=len(CASES), fontsize=9.5, frameon=False)
    runs = run_counts([r for d in data.values() for _, _, r in d.values()])
    smt = ", SMT off" if vendor == "Intel" else ""
    notes = [
        "Fluent 2026 R1 with the 2026 R1 benchmark harness (MIUPS; two warm-up blocks of 10, then 25 timed "
        + "iterations, time steps for the transient landing_gear_15m and lm6000_16m), IntelMPI over EFA,",
        f"192 cores: one node of the 192-core types, two of the 96-core types{smt}. Median of {runs} runs per "
        + "point. EC2 cost per run: nodes x time x the On-Demand Linux price",
        f"in eu-north-1 (October 2026), against one {reference} node. AWS runs of August 2026 in eu-north-1.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("Ansys Fluent on four smaller cases of the benchmark suite: "
                 + f"{NUMBER_WORDS[len(types)]} {vendor} instance types on 192 cores", fontsize=13,
                 fontweight="bold")
    plt.tight_layout(rect=(0, 0.6 / height_in, 1, 1 - 0.32 / height_in))  # the suptitle's height is added
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


scaling_chart()
flex_chart()
for cpu_vendor in INSTANCES:
    instances_chart(cpu_vendor)

# ---------------------------------------------------------------------------
# Also print the README's tables (rows only) from the data above
# ---------------------------------------------------------------------------
def times(v):
    return f"{v:.2f}×"


def value_range(values, fmt=times):
    """'1.49–1.55×' for a range, '0.56×' when both ends round alike."""
    lo, hi = fmt(min(values)), fmt(max(values))
    return lo if lo == hi else f"{lo[:-1]}–{hi}"


print("\n=== f1_racecar_140m: relative performance, parallel efficiency, EC2 cost per run (1 to 16 nodes) ===")
for itype, points in SCALING.items():
    eff = efficiency(points)
    print(f"| `{itype}` | Relative performance | " + " | ".join(times(points[n][0]) for n in NODES) + " |")
    print("| | Parallel efficiency | — | " + " | ".join(f"{100 * eff[n]:.0f}%" for n in NODES[1:]) + " |")
    print("| | EC2 cost per run | " + " | ".join(times(1 / eff[n]) for n in NODES) + " |")
print("\n=== f1_racecar_140m, the same ranks on more nodes (full shape = 1.00): speed, EC2 cost, licence ===")
for itype in SCALING:
    for rpn, mult in ((96, 2), (48, 4), (24, 8)):
        found = {total: shapes[(total // rpn, rpn)] for (t, total), shapes in FLEX.items()
                 if t == itype and (total // rpn, rpn) in shapes}
        totals = sorted(found)
        span = (", ".join(f"{v:,}" for v in totals) if len(totals) < 3 else f"{totals[0]:,}–{totals[-1]:,}")
        speed = [found[t][0] for t in totals]
        cost = [found[t][1] for t in totals]
        first = f"| `{itype}` |" if rpn == 96 else "| |"
        print(f"{first} {rpn} | {mult}× | {span} | {value_range(speed)} | {value_range(cost)} | "
              + f"{value_range([1 / s for s in speed])} |")
for cpu_vendor, types in INSTANCES.items():
    print(f"\n=== 192 cores, {cpu_vendor} (1 x {REFERENCE[cpu_vendor]} = 1.00): speed per case, "
          + "EC2 cost per run ===")
    for itype, d in types.items():
        print(f"| `{itype}` | {LAYOUT[cpu_vendor][itype][0]} × {LAYOUT[cpu_vendor][itype][1]} | "
              + " | ".join(times(d[case][0]) for case in CASES)
              + f" | {value_range([d[case][1] for case in CASES])} |")
