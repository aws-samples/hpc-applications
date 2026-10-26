#!/usr/bin/env python3
"""
Generate the WRF CONUS 2.5km whole-run chart: the full 6-hour forecast (1,440
steps of 15 s) with its history and restart files written through PnetCDF
(io_form_history = io_form_restart = 11), on four instance types, 1 to 16
nodes, as relative performance against one hpc7a.96xlarge node (= 1.00, higher
is faster), next to each type's parallel efficiency against its own single node.

Timing basis: the whole run, i.e. the wall time of wrf.exe from the start of
mpirun to its exit, output included (the scripts' "Total WRF time"). Per
configuration (instance type, node count) the median over its runs is taken;
relative performance = the 1 x hpc7a.96xlarge median / the configuration's
median. Only relative values and run counts are embedded here.

The compute alone (the steady step, output left out) is charted by
generate_conus2p5km_chart.py.

Usage (from this directory):
    python3 generate_conus2p5km_pnetcdf_chart.py
"""

import matplotlib

matplotlib.use("Agg")  # write the PNG without a display

import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

# ---------------------------------------------------------------------------
# Measured data: relative performance (1 x hpc7a.96xlarge = 1.00) and run count
# per node count. WRF 4.6.1, CONUS 2.5km (1501 x 1201 x 50), the 6-hour forecast
# with hourly history output and a restart write, both through PnetCDF to FSx for
# Lustre; AWS runs of October 2026 in eu-north-1. Every node fully populated,
# one MPI rank per core (OMP_NUM_THREADS=1), EFA, the GCC 11 + Intel MPI build
# (dmpar) with Intel MPI 2021.18 and the settings of
# x86/wrf-benchmark-conus2.5km-intel.sbatch.
# ---------------------------------------------------------------------------
DATA = {
    # type             {nodes: (relative performance, runs)}
    "hpc8a.96xlarge": {1: (1.3923, 2), 2: (2.7798, 2), 4: (5.3979, 2), 8: (9.7480, 2)},
    "c8i.96xlarge":   {1: (1.3712, 2), 2: (2.6020, 2)},
    "hpc7a.96xlarge": {1: (1.0000, 2), 2: (2.0378, 2), 4: (3.9397, 2), 8: (7.2542, 2)},
    "hpc6a.48xlarge": {1: (0.4199, 2), 2: (0.8089, 2), 4: (1.6406, 2), 8: (3.2525, 2),
                       16: (6.1500, 2)},
}

# type: (legend label, colour, marker,
#        end-label offset in points (dx, dy), left panel and right panel)
# The colours and markers are those of WRF-CONUS2.5km-6h-Scaling.png.
STYLE = {
    "hpc8a.96xlarge": ("hpc8a.96xlarge (192 cores/node)", "#232F3E", "o", (7, 0), (7, -4)),
    "c8i.96xlarge":   ("c8i.96xlarge (192)", "#59A14F", "D", None, None),
    "hpc7a.96xlarge": ("hpc7a.96xlarge (192)", "#FF9900", "s", (7, 0), (7, 4)),
    "hpc6a.48xlarge": ("hpc6a.48xlarge (96)", "#B07AA1", "P", (7, 0), (7, 0)),
}

NODES = [1, 2, 4, 8, 16]
FIG_SIZE = (15, 6.8)
DPI = 150
OUTPUT = "WRF-CONUS2.5km-6h-PnetCDF-Scaling.png"


def efficiency(points):
    """Speed-up over the type's own single node, divided by the node count."""
    one = points[1][0]
    return {n: rel / one / n for n, (rel, _) in points.items()}


def plot_series(ax, nodes, values, runs, colour, marker, label):
    """One line per type; a hollow marker where a point was measured by one run."""
    ax.plot(nodes, values, "-", color=colour, linewidth=2, label=label, zorder=2)
    for x, y, r in zip(nodes, values, runs):
        ax.plot([x], [y], marker=marker, markersize=8, color=colour,
                markeredgecolor=colour, markeredgewidth=1.5,
                markerfacecolor=colour if r > 1 else "white", zorder=3)


def end_label(ax, x, y, text, offset, colour):
    """Value label at a series' last point (8 or 16 nodes only, where there is room)."""
    if offset is None:
        return
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
    plot_series(ax1, nodes, rel, [points[n][1] for n in nodes], colour, marker, label)
    end_label(ax1, nodes[-1], rel[-1], f"{rel[-1]:.2f}", offset, colour)

node_axis(ax1)
ax1.set_yscale("log", base=2)
ax1.yaxis.set_major_locator(FixedLocator([0.25, 0.5, 1, 2, 4, 8, 16]))
ax1.yaxis.set_minor_locator(NullLocator())
ax1.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
ax1.set_ylim(0.3, 18)
ax1.set_ylabel("Relative performance (1 x hpc7a.96xlarge = 1.00, higher is faster)")
ax1.set_title("Relative performance, whole run")
ax1.legend(loc="upper left", fontsize=9)

# --- Right: parallel efficiency ---------------------------------------------------
for itype, points in DATA.items():
    label, colour, marker, _, offset = STYLE[itype]
    eff = efficiency(points)
    nodes = sorted(eff)
    pct = [100 * eff[n] for n in nodes]
    plot_series(ax2, nodes, pct, [points[n][1] for n in nodes], colour, marker, label)
    end_label(ax2, nodes[-1], pct[-1], f"{pct[-1]:.0f}%", offset, colour)

node_axis(ax2)
ax2.axhline(100, color="gray", linestyle=":", linewidth=1.2, zorder=1)
ax2.set_ylim(80, 110)
ax2.set_ylabel("Parallel efficiency (%)")
ax2.set_title("Parallel efficiency: speed-up over 1 node of the same type / nodes")

# --- Notes: the metric and the run counts ---------------------------------------------
runs = sorted({r for points in DATA.values() for _, r in points.values()})
runs_text = " or ".join(str(r) for r in runs)
notes = [
    "Whole run: the wall time of wrf.exe, output included (7 hourly history writes and a restart write, "
    + "through PnetCDF to FSx for Lustre).",
    f"Median of {runs_text} runs per point. Every node fully populated, one MPI rank per core, EFA; "
    + "GCC + Intel MPI build; AWS runs of October 2026.",
]
fig.text(0.01, 0.005, "\n".join(notes), fontsize=9, style="italic", color="dimgray",
         ha="left", va="bottom")
fig.suptitle("WRF 4.6.1 CONUS 2.5km, full 6-hour forecast with PnetCDF output: scaling of the whole run",
             fontsize=13, fontweight="bold")
plt.tight_layout(rect=(0, 0.06, 1, 1))
plt.savefig(OUTPUT, dpi=DPI)
print(f"Wrote {OUTPUT}")

# ---------------------------------------------------------------------------
# Also print a summary table for reference (the README's table)
# ---------------------------------------------------------------------------
print("\n=== Relative performance (1 x hpc7a.96xlarge = 1.00), runs, efficiency ===")
print(f"{'Type':<16}" + "".join(f"{str(n) + 'N':>18}" for n in NODES))
for itype, points in DATA.items():
    eff = efficiency(points)
    cells = []
    for n in NODES:
        if n in points:
            rel, r = points[n]
            cells.append(f"{rel:6.2f} ({r}r, {100 * eff[n]:3.0f}%)")
        else:
            cells.append("—")
    print(f"{itype:<16}" + "".join(f"{c:>18}" for c in cells))
