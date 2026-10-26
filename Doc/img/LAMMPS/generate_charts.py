#!/usr/bin/env python3
"""
Generate the LAMMPS Arm chart: Graviton3E (Neoverse V1) against Graviton4
(Neoverse V2). The x86 chart (hpc8a vs hpc7a) is written by
generate_scaling_chart.py.

Benchmark: Lennard-Jones melt (in.lj from LAMMPS bench/), SCALE=4
(2,048,000 atoms, 100 timesteps).

Speedup is normalised to a single Graviton3E node, matching the
OpenRadioss / WRF convention used elsewhere in this repo.

Usage:
    python3 generate_charts.py
"""

import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Measured data: in.lj at SCALE=4 for 100 timesteps, pure MPI, compared on
# the LAMMPS-reported Loop time. Each value is the mean Loop time of 3 runs on
# one Graviton3E node over the mean of the configuration's 3 runs, so higher
# is faster. Only relative values and run counts are embedded here.
# ---------------------------------------------------------------------------
RUNS = 3  # runs per configuration

# Graviton3E (64 cores per node, OpenMPI 4): 1, 2 and 4 nodes
nodes_arm = np.array([1, 2, 4])
su_hpc7g = np.array([1.0000, 1.8846, 3.2274])

# Graviton4 (192 cores per node, OpenMPI 5): 1 and 2 nodes; 4N data not
# collected in this sweep. Plotted as a partial curve.
nodes_m8g = np.array([1, 2])
su_m8g = np.array([4.0846, 5.4762])

# ---------------------------------------------------------------------------
# Styling — match WRF / OpenRadioss convention
# ---------------------------------------------------------------------------
BAR_W = 0.35
HPC7G_COLOR = "#4E79A7"
M8G_COLOR   = "#F28E2B"

# ---------------------------------------------------------------------------
# Chart — Arm Graviton3E vs Graviton4
# ---------------------------------------------------------------------------
fig, ax = plt.subplots(figsize=(9, 6))
x_pos = np.arange(len(nodes_arm))

ax.bar(x_pos - BAR_W/2, su_hpc7g, BAR_W, color=HPC7G_COLOR,
       edgecolor='black', label='hpc7g (Graviton3E, 64 c/n)')

# m8g only has 1N and 2N data; show those bars and an empty slot at 4N
m8g_bars = []
for n in nodes_arm:
    idx = list(nodes_m8g).index(n) if n in nodes_m8g else None
    m8g_bars.append(su_m8g[idx] if idx is not None else 0)
m8g_bars = np.array(m8g_bars)
ax.bar(x_pos + BAR_W/2, m8g_bars, BAR_W, color=M8G_COLOR,
       edgecolor='black', label='m8g (Graviton4, 192 c/n)')

for i, v in enumerate(su_hpc7g):
    ax.text(i - BAR_W/2, v + 0.08, f"{v:.2f}x",
            ha='center', va='bottom', fontsize=9, fontweight='bold')
for i, v in enumerate(m8g_bars):
    if v > 0:
        ax.text(i + BAR_W/2, v + 0.08, f"{v:.2f}x",
                ha='center', va='bottom', fontsize=9, fontweight='bold')

ax.set_xticks(x_pos)
ax.set_xticklabels([f"{n}N" for n in nodes_arm])
ax.set_xlabel("Number of nodes  (hpc7g: 64 c/n, m8g: 192 c/n)")
ax.set_ylabel("Speedup vs 1 node hpc7g  (higher is better)")
ax.set_title("LAMMPS — Lennard-Jones melt (2,048,000 atoms, 100 timesteps)",
             fontsize=12)
ax.grid(True, axis='y', linestyle='--', alpha=0.5)
ax.legend(loc='upper left')
ax.set_ylim(0, max(su_hpc7g.max(), m8g_bars.max()) * 1.20)

fig.suptitle("LAMMPS — Graviton3E (hpc7g) vs Graviton4 (m8g)   "
             "[GCC + OpenMPI 4/5 + EFA]",
             fontsize=13, fontweight='bold', y=1.00)
plt.tight_layout()
plt.savefig("LAMMPS-LJ-Graviton3VsGraviton4.png",
            dpi=150, bbox_inches='tight')
print("Wrote LAMMPS-LJ-Graviton3VsGraviton4.png")

# ---------------------------------------------------------------------------
# Summary table (the README's)
# ---------------------------------------------------------------------------
print("\n=== Arm LJ s=4: relative performance (1 Graviton3E node = 1.00), "
      f"{RUNS} runs per point ===")
print(f"{'Nodes':<6}{'Graviton3E':>12}{'Graviton4':>12}")
for i, n in enumerate(nodes_arm):
    if n in nodes_m8g:
        m_idx = list(nodes_m8g).index(n)
        print(f"{n}N    {su_hpc7g[i]:>11.2f}x{su_m8g[m_idx]:>11.2f}x")
    else:
        print(f"{n}N    {su_hpc7g[i]:>11.2f}x{'—':>12}")
