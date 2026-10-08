#!/usr/bin/env python3
"""
Generate the WRF CONUS 2.5km scaling chart: the full 6-hour forecast (1,440
steps of 15 s) on six instance types, 1 to 16 nodes, as relative performance
against one hpc7a.96xlarge node (= 1.00, higher is faster), next to each type's
parallel efficiency against its own single node.

Timing basis: the steady step, i.e. the average time per step over every step
but the first and those that write output or read boundaries (WRF counts each
history or restart write in the step that makes it, and the writes do not get
faster with more nodes). Per configuration (instance type, node count) the
median over its runs is taken; relative performance = the 1 x hpc7a.96xlarge
median / the configuration's median. Only relative values and run counts are
embedded here.

Usage (from this directory):
    python3 generate_conus2p5km_chart.py
"""

import matplotlib

matplotlib.use("Agg")  # write the PNG without a display

import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data: relative performance (1 x hpc7a.96xlarge = 1.00) and run count
# per node count. WRF 4.6.1, CONUS 2.5km (1501 x 1201 x 50), the 6-hour forecast
# with hourly history output, AWS runs of October 2026 (read 2026-10-09). Every
# node fully populated, one MPI rank per core (OMP_NUM_THREADS=1), EFA:
#   x86        the GCC 11 + Intel MPI build (dmpar), Intel MPI 2021.17 or
#              2021.18 with the settings of x86/wrf-benchmark-conus2.5km-intel.sbatch
#   Graviton4  the Spack GCC build (dm+sm, run pure MPI) with OpenMPI 5.0.9,
#              launched as Arm/wrf-benchmark.sbatch does
# ---------------------------------------------------------------------------
DATA = {
    # type             {nodes: (relative performance, runs)}
    "hpc8a.96xlarge": {1: (1.379, 3), 2: (2.851, 3), 4: (5.915, 3), 8: (12.679, 3)},
    "c8i.96xlarge":   {1: (1.376, 3), 2: (2.755, 3)},
    "m8a.48xlarge":   {1: (1.261, 1), 2: (2.583, 1)},
    "m8g.48xlarge":   {1: (1.134, 3), 2: (2.191, 3), 4: (4.327, 3), 8: (8.697, 2)},
    "hpc7a.96xlarge": {1: (1.000, 3), 2: (2.071, 3), 4: (4.308, 3), 8: (9.299, 3)},
    "hpc6a.48xlarge": {1: (0.408, 3), 2: (0.798, 3), 4: (1.657, 3), 8: (3.464, 3),
                       16: (7.102, 4)},
}

# Points whose runs come from two AWS Regions with a visible gap: marked "†".
REGION_NOTES = {
    ("hpc6a.48xlarge", 16): "hpc6a.48xlarge on 16 nodes: median of 4 runs. Both us-east-2 "
                            "runs, on separately launched nodes, were about 5% slower than "
                            "both eu-north-1 runs (median step slower in every hour): this "
                            "points to the Regions' software.",
}
# The note is written for these 4 runs: re-check its text when a run is added there.
assert DATA["hpc6a.48xlarge"][16][1] == 4, "re-check REGION_NOTES"

# type: (legend label, colour, marker,
#        end-label offset in points (dx, dy), left panel and right panel)
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 cores/node)", "#232F3E", "o", (7, 0), (7, -6)),
    "c8i.96xlarge":   ("c8i.96xlarge (192)", "#59A14F", "D", None, None),
    "m8a.48xlarge":   ("m8a.48xlarge (192)", "#E15759", "v", None, None),
    "m8g.48xlarge":   ("m8g.48xlarge (192, Graviton4)", "#4E79A7", "^", (7, -7), (7, 0)),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s", (7, 5), (7, 6)),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P", (7, 0), (7, 0)),
}

# Markers drawn above the others: m8g and hpc7a nearly coincide on 4 nodes, and
# the smaller triangle stays visible on top of the square.
MARKERS_ON_TOP = {"m8g.48xlarge"}

NODES = [1, 2, 4, 8, 16]
FIG_SIZE = (15, 6.8)
DPI = 150
OUTPUT = "WRF-CONUS2.5km-6h-Scaling.png"


def efficiency(points):
    """Speed-up over the type's own single node, divided by the node count."""
    one = points[1][0]
    return {n: rel / one / n for n, (rel, _) in points.items()}


def plot_series(ax, itype, nodes, values, runs, colour, marker, label):
    """One line per type; a hollow marker where a point was measured by one run."""
    ax.plot(nodes, values, "-", color=colour, linewidth=2, label=label, zorder=2)
    for x, y, r in zip(nodes, values, runs):
        ax.plot([x], [y], marker=marker, markersize=8, color=colour,
                markeredgecolor=colour, markeredgewidth=1.5,
                markerfacecolor=colour if r > 1 else "white",
                zorder=4 if itype in MARKERS_ON_TOP else 3)


def end_label(ax, itype, x, y, text, offset, colour):
    """Value label at a series' last point (8 or 16 nodes only, where there is room)."""
    if offset is None:
        return
    if (itype, x) in REGION_NOTES:
        text += "†"
    ax.annotate(text, (x, y), xytext=offset, textcoords="offset points",
                ha="left", va="center", fontsize=9, fontweight="bold", color=colour)


def node_axis(ax):
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(NODES))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}"))
    ax.set_xlim(0.85, 24)
    ax.set_xlabel("Number of nodes")
    ax.grid(True, which="major", linestyle="--", alpha=0.5)


fig, (ax1, ax2) = plt.subplots(1, 2, figsize=FIG_SIZE)

# --- Left: relative performance ------------------------------------------------
for itype, points in DATA.items():
    label, colour, marker, offset, _ = STYLE[itype]
    nodes = sorted(points)
    rel = [points[n][0] for n in nodes]
    plot_series(ax1, itype, nodes, rel, [points[n][1] for n in nodes], colour, marker, label)
    end_label(ax1, itype, nodes[-1], rel[-1], f"{rel[-1]:.2f}", offset, colour)

node_axis(ax1)
ax1.set_yscale("log", base=2)
ax1.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4, 8, 16]))
ax1.yaxis.set_minor_locator(NullLocator())
ax1.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
ax1.set_ylim(0.3, 18)
ax1.set_ylabel("Relative performance (1 x hpc7a.96xlarge = 1.00, higher is faster)")
ax1.set_title("Relative performance")
ax1.legend(loc="upper left", fontsize=9)

# --- Right: parallel efficiency ---------------------------------------------------
for itype, points in DATA.items():
    label, colour, marker, _, offset = STYLE[itype]
    eff = efficiency(points)
    nodes = sorted(eff)
    pct = [100 * eff[n] for n in nodes]
    plot_series(ax2, itype, nodes, pct, [points[n][1] for n in nodes], colour, marker, label)
    end_label(ax2, itype, nodes[-1], pct[-1], f"{pct[-1]:.0f}%", offset, colour)

node_axis(ax2)
ax2.axhline(100, color="gray", linestyle=":", linewidth=1.2, zorder=1)
ax2.set_ylim(90, 120)
ax2.set_ylabel("Parallel efficiency (%)")
ax2.set_title("Parallel efficiency: speed-up over 1 node of the same type / nodes")

# --- Notes: the metric, the run counts, the marked points ----------------------------
single = {}
for itype, points in DATA.items():
    ones = [n for n, (_, runs) in sorted(points.items()) if runs == 1]
    if ones:
        single[itype] = ones
multi = sorted({runs for points in DATA.values() for _, runs in points.values() if runs > 1})


def join_words(words, conj):
    """'a', 'a and b', 'a, b and c' (conj is 'and' or 'or')."""
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + f" {conj} " + words[-1]


def nodes_text(nodes):
    return f"{join_words([str(n) for n in nodes], 'and')} node" + ("" if nodes == [1] else "s")


# A clause for each kind of marker the chart has (once every point has repeats, no hollow one)
marker_notes = []
if multi:
    marker_notes.append("filled markers: median of "
                        f"{join_words([str(r) for r in multi], 'or')} runs")
if single:
    marker_notes.append("hollow markers: 1 run ("
                        + ", ".join(f"{t} on {nodes_text(n)}" for t, n in single.items()) + ")")
markers_text = "; ".join(marker_notes)

notes = [
    "Steady step: every step but the first and those that write output or read boundaries "
    "(WRF counts each hourly history write and the restart write in the step that makes it).",
    markers_text[:1].upper() + markers_text[1:]
    + ". Every node fully populated, one MPI rank per core, EFA; AWS runs of October 2026.",
] + [f"† {text}" for text in REGION_NOTES.values()]
fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray",
         ha="left", va="bottom")
fig.suptitle("WRF 4.6.1 CONUS 2.5km, full 6-hour forecast: scaling of the steady step",
             fontsize=13, fontweight="bold")
plt.tight_layout(rect=(0, 0.075, 1, 1))
plt.savefig(OUTPUT, dpi=DPI)
print(f"Wrote {OUTPUT}")

# ---------------------------------------------------------------------------
# Also print a summary table for reference
# ---------------------------------------------------------------------------
print("\n=== Relative performance (1 x hpc7a.96xlarge = 1.00), runs, efficiency ===")
print(f"{'Type':<16}" + "".join(f"{str(n) + 'N':>18}" for n in NODES))
for itype, points in DATA.items():
    eff = efficiency(points)
    cells = []
    for n in NODES:
        if n in points:
            rel, runs = points[n]
            cells.append(f"{rel:6.2f} ({runs}r, {100 * eff[n]:3.0f}%)")
        else:
            cells.append("—")
    print(f"{itype:<16}" + "".join(f"{c:>18}" for c in cells))
