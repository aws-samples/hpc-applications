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
# Measured data — LAMMPS LJ s=4, Loop time (s), means of N replicas.
# Pulled from DynamoDB table LAMMPS_Benchmarks (us-east-1).
# ---------------------------------------------------------------------------

# Arm ---------------------------------------------------------------------
nodes_arm = np.array([1, 2, 4])

# hpc7g (Graviton3E, OpenMPI 4): 3 replicas at every node count
t_hpc7g_1n = [1.93697, 1.94593, 1.94921]
t_hpc7g_2n = [1.01968, 1.03134, 1.04365]
t_hpc7g_4n = [0.594353, 0.600465, 0.612252]
t_hpc7g = np.array([np.mean(t_hpc7g_1n),
                    np.mean(t_hpc7g_2n),
                    np.mean(t_hpc7g_4n)])

# m8g (Graviton4, OpenMPI 5): 3 replicas at 1N and 2N; 4N data not collected
# in this sweep. Plotted as a partial curve.
t_m8g_1n = [0.473154, 0.475054, 0.479638]
t_m8g_2n = [0.352756, 0.352925, 0.359313]
nodes_m8g = np.array([1, 2])
t_m8g = np.array([np.mean(t_m8g_1n),
                  np.mean(t_m8g_2n)])

# ---------------------------------------------------------------------------
# Speedups
# ---------------------------------------------------------------------------
baseline_arm = t_hpc7g[0]   # 1N hpc7g

su_hpc7g = baseline_arm / t_hpc7g
su_m8g   = baseline_arm / t_m8g

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
# Summary table
# ---------------------------------------------------------------------------
print("\n=== Arm LJ s=4 Loop time (s) ===")
print(f"{'Nodes':<6}{'hpc7g':>10}{'m8g':>10}{'hpc7g_su':>12}{'m8g_su':>12}")
for i, n in enumerate(nodes_arm):
    if n in nodes_m8g:
        m_idx = list(nodes_m8g).index(n)
        print(f"{n}N    {t_hpc7g[i]:>10.4f}{t_m8g[m_idx]:>10.4f}"
              f"{su_hpc7g[i]:>11.2f}x{su_m8g[m_idx]:>11.2f}x")
    else:
        print(f"{n}N    {t_hpc7g[i]:>10.4f}{'—':>10}"
              f"{su_hpc7g[i]:>11.2f}x{'—':>12}")
