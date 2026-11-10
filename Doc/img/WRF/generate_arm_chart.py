#!/usr/bin/env python3
"""
Generate the WRF Arm performance chart: Graviton3E (hpc7g) vs Graviton4 (m8g)
for CONUS 12km and CONUS 2.5km benchmarks. Speedup normalised to 1 node hpc7g
on each mesh. The Graviton3E 1N 2.5km baseline is not measured: it is
estimated as 2 x the 2N time, the convention of the OpenFOAM Arm chart.

Usage:
    python3 generate_arm_chart.py
"""

import matplotlib
matplotlib.use("Agg")  # write the PNG without a display
import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Measured WRF CONUS benchmark data: speedup on the total wall time (output
# included), against 1 node hpc7g on each mesh (= 1.00, higher is faster).
# Only relative values are embedded here.
# ---------------------------------------------------------------------------
# All runs: OpenMPI 5 over EFA, GCC 14 build via Spack, WRF 4.6.1 dm+sm,
# OMP_NUM_THREADS=1 (pure MPI), 64 cores/node on hpc7g, 192 cores/node on m8g.
# Graviton4 4N 12km is not plotted — the 425x300 grid cannot decompose cleanly
# at >= 512 ranks (minimum 10 cells/rank/direction constraint).

nodes_12km_g3   = np.array([1, 2, 4])
speedup_12km_g3 = np.array([1.0000, 1.7511, 2.5522])
nodes_12km_g4   = np.array([1, 2])
speedup_12km_g4 = np.array([2.5187, 3.4058])

# The 2.5km reference, 1N hpc7g, is the estimate (2 x the 2N time), so the 2N
# hpc7g point is 2.00 by construction.
nodes_2p5km_g3        = np.array([2, 4])
speedup_2p5km_g3_real = np.array([2.0000, 3.2966])
nodes_2p5km_g4        = np.array([1, 2, 4])
speedup_2p5km_g4      = np.array([3.0752, 5.0432, 7.4916])

# Prepend the estimated G3 1N 2.5km baseline (speedup=1.0) for plotting
nodes_2p5km_g3_all   = np.array([1, 2, 4])
speedup_2p5km_g3_all = np.concatenate(([1.0], speedup_2p5km_g3_real))

# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

BAR_W = 0.35
G3_COLOR = "#4E79A7"
G4_COLOR = "#F28E2B"

# --- CONUS 12km ---
x = np.array([1, 2, 4])
x_pos = np.arange(len(x))
g3_vals = [speedup_12km_g3[list(nodes_12km_g3).index(n)] if n in nodes_12km_g3 else None for n in x]
g4_vals = [speedup_12km_g4[list(nodes_12km_g4).index(n)] if n in nodes_12km_g4 else None for n in x]

ax1.bar(x_pos - BAR_W/2, [v if v is not None else 0 for v in g3_vals],
        BAR_W, color=G3_COLOR, edgecolor='black', label='hpc7g (Graviton3E)')
ax1.bar(x_pos + BAR_W/2, [v if v is not None else 0 for v in g4_vals],
        BAR_W, color=G4_COLOR, edgecolor='black', label='m8g (Graviton4)')

for i, v in enumerate(g3_vals):
    if v is not None:
        ax1.text(i - BAR_W/2, v + 0.08, f"{v:.2f}x", ha='center', va='bottom',
                 fontsize=9, fontweight='bold')
for i, v in enumerate(g4_vals):
    if v is not None:
        ax1.text(i + BAR_W/2, v + 0.08, f"{v:.2f}x", ha='center', va='bottom',
                 fontsize=9, fontweight='bold')
# "n/a" marker where Graviton4 4N is omitted
ax1.text(2 + BAR_W/2, 0.15, "decomp\nlimit", ha='center', va='bottom',
         fontsize=8, style='italic', color='gray')

ax1.set_xticks(x_pos)
ax1.set_xticklabels([f"{n}N" for n in x])
ax1.set_xlabel("Number of nodes")
ax1.set_ylabel("Speedup vs 1 node hpc7g (higher is better)")
ax1.set_title("WRF CONUS 12km  (425 × 300, dt=60s)")
ax1.grid(True, axis='y', linestyle='--', alpha=0.5)
ax1.legend(loc='upper left')

# --- CONUS 2.5km ---
x_pos = np.arange(len(x))
g3_vals = speedup_2p5km_g3_all.tolist()
g4_vals = [speedup_2p5km_g4[list(nodes_2p5km_g4).index(n)] if n in nodes_2p5km_g4 else None for n in x]

b3 = ax2.bar(x_pos - BAR_W/2, g3_vals, BAR_W, color=G3_COLOR,
             edgecolor='black', label='hpc7g (Graviton3E)')
ax2.bar(x_pos + BAR_W/2, g4_vals, BAR_W, color=G4_COLOR,
        edgecolor='black', label='m8g (Graviton4)')

# Mark the estimated 1N hpc7g 2.5km bar with a diagonal hatch for clarity
b3[0].set_hatch('///')
b3[0].set_alpha(0.75)

for i, v in enumerate(g3_vals):
    ax2.text(i - BAR_W/2, v + 0.05, f"{v:.2f}x", ha='center', va='bottom',
             fontsize=9, fontweight='bold')
for i, v in enumerate(g4_vals):
    if v is not None:
        ax2.text(i + BAR_W/2, v + 0.05, f"{v:.2f}x", ha='center', va='bottom',
                 fontsize=9, fontweight='bold')

ax2.set_xticks(x_pos)
ax2.set_xticklabels([f"{n}N" for n in x])
ax2.set_xlabel("Number of nodes")
ax2.set_ylabel("Speedup vs 1 node hpc7g (higher is better)")
ax2.set_title("WRF CONUS 2.5km  (1501 × 1201, dt=15s)")
ax2.grid(True, axis='y', linestyle='--', alpha=0.5)
ax2.legend(loc='upper left')

# Note for the estimated bar
ax2.text(0 - BAR_W/2, -0.25, "(est. 2× 2N)",
         ha='center', va='top', fontsize=7, style='italic', color='gray',
         transform=ax2.get_xaxis_transform())

fig.suptitle("WRF 4.6.1 — Graviton3E (hpc7g) vs Graviton4 (m8g)   "
             "[OpenMPI 5 + EFA]", fontsize=13, fontweight='bold', y=1.01)
plt.tight_layout()
plt.savefig("WRF-CONUS-Graviton3VsGraviton4.png",
            dpi=150, bbox_inches='tight')
print("Wrote WRF-CONUS-Graviton3VsGraviton4.png")

# ---------------------------------------------------------------------------
# Also print a summary table for reference
# ---------------------------------------------------------------------------
print("\n=== Speedup summary (vs 1N hpc7g) ===")
print(f"{'Nodes':<8}{'12km G3':>10}{'12km G4':>10}{'2.5km G3':>12}{'2.5km G4':>12}")
for i, n in enumerate([1, 2, 4]):
    g3_12 = f"{speedup_12km_g3[list(nodes_12km_g3).index(n)]:.2f}x" if n in nodes_12km_g3 else "—"
    g4_12 = f"{speedup_12km_g4[list(nodes_12km_g4).index(n)]:.2f}x" if n in nodes_12km_g4 else "—"
    g3_25 = f"{g3_vals[i]:.2f}x" if n == 1 else f"{speedup_2p5km_g3_all[i]:.2f}x"
    g4_25 = f"{speedup_2p5km_g4[list(nodes_2p5km_g4).index(n)]:.2f}x" if n in nodes_2p5km_g4 else "—"
    tag = " (est)" if n == 1 else ""
    print(f"{n}N{tag:<6}{g3_12:>10}{g4_12:>10}{g3_25:>12}{g4_25:>12}")
