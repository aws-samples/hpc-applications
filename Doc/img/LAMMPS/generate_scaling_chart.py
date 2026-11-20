#!/usr/bin/env python3
"""
Generate LAMMPS-Hpc8aVsHpc7a-Scaling.png, the x86 chart of apps/LAMMPS/README.md:
three LAMMPS bench/ decks, each run long enough for its loop to dominate (lj at
SCALE 8 for 15,000 timesteps, rhodo_scaled at SCALE 4 for 6,000, eam at SCALE 4
for 30,000), on 1 to 8 nodes of hpc8a.96xlarge and hpc7a.96xlarge, every node
fully populated, as relative performance against one hpc7a.96xlarge node running
the same deck (= 1.00, higher is faster). Each line's last point is labelled with
its value and its parallel efficiency against the type's own single node; the
dotted lines are ideal scaling from that node.

Timing basis: LAMMPS's own "Total wall time" (the last line of log.lammps). Per
configuration (deck, instance type, node count) the median over its runs is
taken; relative performance = the 1 x hpc7a.96xlarge median / the configuration's
median. Only relative values and run counts are embedded here.

Usage (from this directory):
    python3 generate_scaling_chart.py
"""
import matplotlib
matplotlib.use("Agg")  # write the PNG without a display
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data. LAMMPS stable_2Aug2023_update3, the x86 build of this directory
# (GCC 11, -O3 -march=x86-64-v4 -mtune=znver4, FFTW3; one binary for both types);
# 192 MPI ranks per node, one OpenMP thread each, --bind-to core --map-by slot,
# OpenMPI 4.1.7 over EFA; the decks' run line set to run ${nsteps}; page cache
# dropped and THP set to always before each run; AWS runs of October 2026 in
# eu-north-1.
# deck: {type: {nodes: (relative performance, runs)}}, reference 1 x hpc7a.96xlarge
# of the same deck.
# ---------------------------------------------------------------------------
DATA = {
    "lj": {
        "hpc8a.96xlarge": {1: (1.3898, 3), 2: (2.9710, 3), 4: (6.3077, 3), 8: (11.7143, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (2.1579, 3), 4: (4.4086, 3), 8: (7.9612, 3)},
    },
    "rhodo_scaled": {
        "hpc8a.96xlarge": {1: (1.4640, 3), 2: (2.6457, 3), 4: (4.2143, 3), 8: (4.6825, 1)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.7988, 3), 4: (2.7570, 3), 8: (2.9208, 1)},
    },
    "eam": {
        "hpc8a.96xlarge": {1: (1.3117, 3), 2: (2.4148, 3), 4: (4.0094, 3), 8: (7.4561, 3)},
        "hpc7a.96xlarge": {1: (1.0000, 3), 2: (1.8162, 3), 4: (2.9514, 3), 8: (4.9419, 3)},
    },
}
# deck: panel title (MODEL, SCALE, atoms, timesteps)
TITLES = {
    "lj": "lj, SCALE 8: 16,384,000 atoms, 15,000 timesteps",
    "rhodo_scaled": "rhodo_scaled, SCALE 4: 2,048,000 atoms, 6,000 timesteps",
    "eam": "eam, SCALE 4: 2,048,000 atoms, 30,000 timesteps",
}

# type: (legend label, colour, marker)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 ranks/node)", "#232F3E", "o"),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s"),
}
NODES = [1, 2, 4, 8]
DPI = 150
OUTPUT = "LAMMPS-Hpc8aVsHpc7a-Scaling.png"


def efficiency(points):
    """Speed-up over the type's own single node, divided by the node count."""
    one = points[1][0]
    return {n: rel / one / n for n, (rel, _) in points.items()}


def scaling_chart(output=OUTPUT):
    fig, axes = plt.subplots(1, len(DATA), figsize=(16, 5.8), sharey=True)
    for ax, (deck, spec) in zip(axes, DATA.items()):
        for itype, (label, colour, marker) in STYLE.items():
            points = spec[itype]
            nodes = sorted(points)
            rel = [points[n][0] for n in nodes]
            ax.plot([nodes[0], nodes[-1]], [rel[0], rel[0] * nodes[-1] / nodes[0]], ":", color=colour,
                    linewidth=1.2, alpha=0.7, zorder=1)
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
        ax.set_xlim(0.8, 16)
        ax.set_yscale("log", base=2)
        ax.yaxis.set_major_locator(FixedLocator([1, 2, 4, 8, 16]))
        ax.yaxis.set_minor_locator(NullLocator())
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
        ax.set_ylim(0.8, 16)
        ax.grid(True, which="major", linestyle="--", alpha=0.5)
        ax.set_title(f"{TITLES[deck]}\n(reference: 1 x hpc7a.96xlarge = 1.00)", fontsize=10.5)
        ax.set_xlabel("Number of nodes (every node fully populated)")
    axes[0].set_ylabel("Relative performance (higher is faster)")
    handles = [Line2D([], [], color=c, marker=m, linewidth=2, label=lbl) for lbl, c, m in STYLE.values()]
    handles.append(Line2D([], [], color="gray", linestyle=":", linewidth=1.2, label="ideal scaling from 1 node"))
    axes[0].legend(handles=handles, loc="upper left", fontsize=9)
    # The notes name the single-run points and the other points' run count: re-check them when runs change.
    singles = sorted({(deck, n) for deck, spec in DATA.items() for pts in spec.values()
                      for n, (_, runs) in pts.items() if runs == 1})
    assert singles == [("rhodo_scaled", 8)], singles
    assert {runs for spec in DATA.values() for pts in spec.values() for _, runs in pts.values()} == {1, 3}
    notes = [
        "LAMMPS's own Total wall time (log.lammps). Median of 3 runs per point; hollow: a single run "
        + "(rhodo_scaled on 8 nodes). Dotted: ideal scaling from each type's single node.",
        "Labels: the 8-node value and its parallel efficiency against the type's own single node. 192 MPI ranks "
        + "per node, one OpenMP thread each, OpenMPI 4.1.7 over EFA; AWS runs of October 2026.",
    ]
    fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray", ha="left", va="bottom")
    fig.suptitle("LAMMPS bench decks on hpc8a and hpc7a: scaling with full nodes", fontsize=13, fontweight="bold")
    plt.tight_layout(rect=(0, 0.07, 1, 1))
    plt.savefig(output, dpi=DPI)
    plt.close(fig)
    print(f"Wrote {output}")


scaling_chart()

# ---------------------------------------------------------------------------
# Also print summary tables for reference (the README's tables)
# ---------------------------------------------------------------------------
print("\n=== Relative performance (1 x hpc7a.96xlarge = 1.00), runs, parallel efficiency ===")
for deck, spec in DATA.items():
    print(f"-- {TITLES[deck]}")
    for itype in STYLE:
        points = spec[itype]
        eff = efficiency(points)
        print(f"   {itype:<16}" + "".join(f"{n:>3}N {rel:6.2f} ({runs}r, {100 * eff[n]:3.0f}%)"
                                         for n, (rel, runs) in sorted(points.items())))
print("\n=== hpc8a.96xlarge against hpc7a.96xlarge, node for node ===")
for deck, spec in DATA.items():
    print(f"   {deck:<13}" + "".join(f"{n:>3}N {spec['hpc8a.96xlarge'][n][0] / spec['hpc7a.96xlarge'][n][0]:5.2f}"
                                    for n in NODES))
