#!/usr/bin/env python3
"""
Generate the GROMACS instance-type charts of apps/Gromacs/README.md, for the four
AMD instance types of the October 2026 runs:

1. Gromacs-SingleNode.png: one node of each type on the three MPI-NAT
   benchmarks (benchMEM, benchRIB, benchPEP-h), as relative performance against
   one hpc7a.96xlarge node of the same benchmark (= 1.00, higher is faster).
2. Gromacs-Scaling.png: benchPEP-h on 1 to 8 nodes and benchMEM on 1 to 4 nodes
   of the same four types, relative performance (same reference) next to each
   type's parallel efficiency against its own single node.

benchRIB's points beyond one node are in DATA for the README's benchRIB table,
which the summary printed at the end gives; no chart draws them.

Timing basis: GROMACS's own rate, the ns/day it prints on md.log's Performance
line (mdrun -resethway times the second half of the run). Per configuration
(benchmark, instance type, node count) the median over its runs is taken;
relative performance = the configuration's median rate / the median rate of one
hpc7a.96xlarge node. Only relative values and run counts are embedded here.

The README gives the c8i.96xlarge (Intel) and m8g.48xlarge (Graviton4) runs in
tables of their own, each against one node of the same type; they are not here.

Usage (from this directory):
    python3 generate_instance_charts.py
"""
import matplotlib
matplotlib.use("Agg")  # write the PNGs without a display
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data: relative performance (1 x hpc7a.96xlarge = 1.00) and run count
# per node count, for the four AMD types. GROMACS 2024.4, AWS runs of October
# 2026. Every node fully populated with one MPI rank per core and one OpenMP
# thread per rank (192 ranks per node, 96 on hpc6a.48xlarge), launched as
# x86/gromacs-benchmark.sbatch does (Thread-MPI gmx on one node, gmx_mpi with
# OpenMPI over EFA on more), mdrun -resethway -noconfout -nstlist 100;
# benchPEP-h and benchRIB with -notunepme, benchRIB with a quarter of the ranks
# on PME (-npme), but 90 of the 384 ranks of 2 hpc8a or hpc7a nodes and of 4
# hpc6a nodes, with the PP grid given (-npme 90 -dd 7 7 6).
# Builds: AVX_512 (hpc8a, m8a, hpc7a), AVX2_256 (hpc6a).
# Software stack: ParallelCluster 3.16.0 and EFA installer 1.49.0 in eu-north-1
# (hpc8a, hpc7a, hpc6a), 3.15.0 and 1.47.0 in us-east-2 (m8a); hpc7a and
# hpc6a, which also ran in us-east-2, are their eu-north-1 runs only, so that
# each type has one stack.
# ---------------------------------------------------------------------------
DATA = {
    # benchmark: {type: {nodes: (relative performance, runs)}}; 5 decimals, so the
    # 2-decimal labels are the ratios rounded once
    "benchMEM": {
        "hpc8a.96xlarge": {1: (1.36583, 3), 2: (1.52214, 3), 4: (1.12584, 3)},
        "m8a.48xlarge": {1: (1.17437, 1), 2: (1.25013, 1)},
        "hpc7a.96xlarge": {1: (1.00000, 3), 2: (0.84382, 2), 4: (0.64574, 2)},
        "hpc6a.48xlarge": {1: (0.51017, 2), 2: (0.61198, 2), 4: (0.68318, 2)},
    },
    "benchRIB": {
        "hpc8a.96xlarge": {1: (1.41497, 3), 2: (1.54628, 1)},
        "m8a.48xlarge": {1: (1.16662, 1)},
        "hpc7a.96xlarge": {1: (1.00000, 2), 2: (1.01077, 1)},
        "hpc6a.48xlarge": {1: (0.43417, 2), 2: (0.73489, 2), 3: (1.09791, 3), 4: (0.82161, 1)},
    },
    "benchPEP-h": {
        "hpc8a.96xlarge": {1: (1.38248, 3), 2: (2.71323, 3), 4: (5.06985, 3), 8: (9.89911, 3)},
        "m8a.48xlarge": {1: (0.97857, 1), 2: (1.94383, 1)},
        "hpc7a.96xlarge": {1: (1.00000, 2), 2: (1.96968, 2), 4: (3.69495, 2), 8: (6.87779, 2)},
        "hpc6a.48xlarge": {1: (0.37028, 2), 2: (0.69435, 2), 4: (1.43932, 2), 8: (2.78527, 2)},
    },
}
BENCHMARKS = {
    # benchmark: (atoms, title text)
    "benchMEM": ("82k", "benchMEM (82k atoms)"),
    "benchRIB": ("2.0M", "benchRIB (2.0M atoms)"),
    "benchPEP-h": ("12.5M", "benchPEP-h (12.5M atoms)"),
}
# type: (legend label, colour, marker,
#        end-label offsets in points (dx, dy): benchPEP-h relative and efficiency,
#        benchMEM relative and efficiency; None: no label)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 cores/node)", "#232F3E", "o", (7, 0), (7, -3), (7, 0), (7, 0)),
    "m8a.48xlarge": ("m8a.48xlarge (192)", "#E15759", "v", None, None, None, None),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s", (7, 0), (7, -4), (7, -4), (7, -4)),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P", (7, 0), (7, 4), (7, 4), (7, 4)),
}
NODES = [1, 2, 4, 8]
DPI = 150


def efficiency(points):
    """Speed-up over the type's own single node, divided by the node count."""
    one = points[1][0]
    return {n: rel / one / n for n, (rel, _) in points.items()}


def join_words(words, conj):
    """'a', 'a and b', 'a, b and c' (conj is 'and' or 'or')."""
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + f" {conj} " + words[-1]


def nodes_text(nodes):
    """'1 node', '1 and 2 nodes'."""
    return join_words([str(n) for n in nodes], "and") + (" node" if nodes == [1] else " nodes")


def runs_note(benchmarks, one_node_only):
    """The run counts of the points a chart shows: 'median of 2 or 3 runs' and the 1-run points.

    A type whose 1-run points are the same in every benchmark shown is named once
    (with its node counts on a scaling chart); otherwise each benchmark is named."""
    multi, single = set(), {}
    for bench in benchmarks:
        for itype, pts in DATA[bench].items():
            for n, (_, runs) in sorted(pts.items()):
                if one_node_only and n != 1:
                    continue
                if runs > 1:
                    multi.add(runs)
                else:
                    single.setdefault(itype, {}).setdefault(bench, []).append(n)
    parts = []
    for itype, by_bench in single.items():
        node_sets = list(by_bench.values())
        if len(by_bench) == len(benchmarks) and all(s == node_sets[0] for s in node_sets):
            parts.append(itype if one_node_only else f"{itype} on {nodes_text(node_sets[0])}")
        else:
            for bench, nodes in by_bench.items():
                where = bench if one_node_only else f"{nodes_text(nodes)} of {bench}"
                parts.append(f"{itype} on {where}")
    return f"median of {join_words([str(r) for r in sorted(multi)], 'or')} runs", parts


PROTOCOL_NOTES = [
    "GROMACS 2024.4, one MPI rank per core (192 per node, 96 on hpc6a.48xlarge); benchPEP-h and benchRIB "
    + "with -notunepme.",
    "Rate: md.log's ns/day (mdrun -resethway times the second half of the run). AWS runs of October 2026: m8a "
    + "in us-east-2, the others in eu-north-1.",
]


# ---------------------------------------------------------------------------
# 1. One node of each type, the three benchmarks
# ---------------------------------------------------------------------------
def single_node_chart(output="Gromacs-SingleNode.png"):
    fig, ax = plt.subplots(figsize=(12, 6.4))
    types = list(STYLE)
    width = 0.19
    for g, bench in enumerate(BENCHMARKS):
        for i, itype in enumerate(types):
            rel, runs = DATA[bench][itype][1]
            colour = STYLE[itype][1]
            x = g + (i - (len(types) - 1) / 2) * width
            single = runs == 1
            ax.bar(x, rel, width * 0.92, color="white" if single else colour, edgecolor=colour,
                   linewidth=1.5, hatch="///" if single else None,
                   label=STYLE[itype][0] if g == 0 else None, zorder=3)
            ax.annotate(f"{rel:.2f}", (x, rel), xytext=(0, 3), textcoords="offset points", ha="center",
                        va="bottom", fontsize=8, fontweight="bold", color=colour)
    ax.axhline(1.0, color="gray", linestyle=":", linewidth=1.2, zorder=2)
    ax.set_xticks(range(len(BENCHMARKS)))
    ax.set_xticklabels([BENCHMARKS[b][1] for b in BENCHMARKS], fontsize=10.5)
    ax.set_ylim(0, 1.7)
    ax.set_ylabel("Relative performance (1 x hpc7a.96xlarge = 1.00, higher is faster)")
    ax.grid(True, axis="y", linestyle="--", alpha=0.5, zorder=0)
    ax.legend(loc="upper left", fontsize=9, ncol=4)
    median_text, ones = runs_note(list(BENCHMARKS), one_node_only=True)
    runs_text = median_text[:1].upper() + median_text[1:] + " per bar"
    if ones:
        runs_text += f"; hatched bars: 1 run ({'; '.join(ones)})"
    notes = [runs_text + "."] + PROTOCOL_NOTES
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    ax.set_title("GROMACS on one node of four AMD instance types: the MPI-NAT benchmarks", fontsize=13,
                 fontweight="bold")
    plt.tight_layout(rect=(0, 0.08, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


# ---------------------------------------------------------------------------
# 2. Scaling: benchPEP-h and benchMEM, relative performance and efficiency
# ---------------------------------------------------------------------------
def plot_series(ax, nodes, values, runs, colour, marker, label):
    """One line per type; a hollow marker where a point was measured by one run."""
    ax.plot(nodes, values, "-", color=colour, linewidth=2, label=label, zorder=2)
    for x, y, r in zip(nodes, values, runs):
        ax.plot([x], [y], marker=marker, markersize=7.5, color=colour, markeredgecolor=colour,
                markeredgewidth=1.5, markerfacecolor=colour if r > 1 else "white", zorder=3)


def end_label(ax, x, y, text, offset, colour):
    if offset is None:
        return
    ax.annotate(text, (x, y), xytext=offset, textcoords="offset points", ha="left", va="center",
                fontsize=8.5, fontweight="bold", color=colour)


def node_axis(ax, last):
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator([n for n in NODES if n <= last]))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.set_xlim(0.85, last * 1.6)
    ax.set_xlabel("Number of nodes (every node fully populated)")
    ax.grid(True, which="major", linestyle="--", alpha=0.5)


def scaling_chart(output="Gromacs-Scaling.png"):
    fig, axes = plt.subplots(2, 2, figsize=(15, 11.5))
    rows = (("benchPEP-h", 8, 3, 4), ("benchMEM", 4, 5, 6))
    for (bench, last, rel_slot, eff_slot), (ax_rel, ax_eff) in zip(rows, axes):
        for itype, points in DATA[bench].items():
            style = STYLE[itype]
            label, colour, marker = style[:3]
            nodes = sorted(points)
            rel = [points[n][0] for n in nodes]
            runs = [points[n][1] for n in nodes]
            plot_series(ax_rel, nodes, rel, runs, colour, marker, label)
            eff = efficiency(points)
            pct = [100 * eff[n] for n in nodes]
            plot_series(ax_eff, nodes, pct, runs, colour, marker, label)
            if len(nodes) > 1 and nodes[-1] == last:
                end_label(ax_rel, nodes[-1], rel[-1], f"{rel[-1]:.2f}", style[rel_slot], colour)
                end_label(ax_eff, nodes[-1], pct[-1], f"{pct[-1]:.0f}%", style[eff_slot], colour)
        node_axis(ax_rel, last)
        node_axis(ax_eff, last)
        if bench == "benchPEP-h":
            ax_rel.set_yscale("log", base=2)
            ax_rel.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4, 8, 16]))
            ax_rel.yaxis.set_minor_locator(NullLocator())
            ax_rel.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
            ax_rel.set_ylim(0.3, 14)
            ax_eff.set_ylim(80, 105)
        else:
            ax_rel.set_ylim(0, 1.9)
            ax_eff.set_ylim(0, 105)
        ax_eff.axhline(100, color="gray", linestyle=":", linewidth=1.2, zorder=1)
        title = BENCHMARKS[bench][1]
        ax_rel.set_title(f"{title}: relative performance (1 x hpc7a.96xlarge = 1.00)", fontsize=11)
        ax_eff.set_title(f"{title}: parallel efficiency against 1 node of the same type", fontsize=11)
        ax_rel.set_ylabel("Relative performance (higher is faster)")
        ax_eff.set_ylabel("Parallel efficiency (%)")
    axes[0, 0].legend(loc="upper left", fontsize=9)
    median_text, ones = runs_note([bench for bench, *_ in rows], one_node_only=False)
    runs_text = f"Filled markers: {median_text}"
    if ones:
        runs_text += f"; hollow markers: 1 run ({'; '.join(ones)})"
    notes = [runs_text + "."] + PROTOCOL_NOTES
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("GROMACS scaling on four AMD instance types: benchPEP-h keeps scaling to 8 nodes, benchMEM gains "
                 + "little beyond one", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.05, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


single_node_chart()
scaling_chart()

# ---------------------------------------------------------------------------
# Also print summary tables for reference (the README's tables)
# ---------------------------------------------------------------------------
for bench, spec in DATA.items():
    print(f"\n=== {bench}: relative performance (1 x hpc7a.96xlarge = 1.00), runs, efficiency ===")
    print(f"{'Nodes':<6}" + "".join(f"{t:>26}" for t in STYLE))
    for n in sorted({n for pts in spec.values() for n in pts}):
        cells = []
        for itype in STYLE:
            pts = spec.get(itype, {})
            if n in pts:
                rel, runs = pts[n]
                cells.append(f"{rel:5.2f} ({runs}r, {100 * efficiency(pts)[n]:3.0f}%)")
            else:
                cells.append("-")
        if any(c != "-" for c in cells):
            print(f"{n:<6}" + "".join(f"{c:>26}" for c in cells))
