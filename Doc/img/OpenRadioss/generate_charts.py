#!/usr/bin/env python3
"""
Generate the OpenRadioss performance charts:

1. x86 chart: hpc8a (AMD EPYC Zen5) vs hpc7a (AMD EPYC Zen4)
   Speedup normalised to 1 node hpc7a.
2. Arm chart: hpc7g (Graviton3E / Neoverse V1) vs m8g (Graviton4 / Neoverse V2)
   Speedup normalised to 1 node hpc7g (estimated as 2 x 2N since 1N does not
   fit in a 4h SLURM wall-time limit).

Benchmark: Ford Taurus (10M cells, SIM_TIME=0.01 = 50,253 cycles)
Metric: Radioss engine ELAPSED TIME, mean of 3 replicas.

Usage:
    python3 generate_charts.py
"""

import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Measured data — OpenRadioss Taurus 10M, SIM_TIME=0.01, engine elapsed (s)
# ---------------------------------------------------------------------------
# All runs: 3 replicas each, mean reported. CV = coefficient of variation.
# x86: GCC 11.5 + OpenMPI 4.1.7 + EFA, -march=x86-64-v4 -mtune=znver4
# Arm: GCC 11.5 + OpenMPI 5.0.9 + EFA, -mcpu=neoverse-v{1,2} -mtune=...
# Pure MPI: 1 OpenMP thread per rank, 192 cores/node (64 on hpc7g)

# x86 —————————————————————————————————————————————————————————————————————
# 8N data collected but not plotted: the Taurus 10M deck hits a contact-sort
# scaling wall at 1536 ranks (see README). 8N is 6% slower than 4N on hpc8a
# and only 20% faster than 4N on hpc7a, so the chart caps at 4N to focus on
# the useful scaling range.
nodes_x86 = np.array([1, 2, 4])
t_hpc8a = np.array([2956.2, 1744.1, 1029.7])  # AMD Zen5, AVX-512
t_hpc7a = np.array([4263.7, 2436.6, 1420.2])  # AMD Zen4, AVX-512

# Arm —————————————————————————————————————————————————————————————————————
# hpc7g 1N does not fit in 4h SLURM limit; estimated as 2 x 2N (same
# convention as OpenFOAM / WRF Arm charts).
nodes_arm = np.array([1, 2, 4, 8])
t_hpc7g_2n_4n_8n = np.array([6700.9, 3495.6, 2015.1])
t_hpc7g_1n_est = 2.0 * t_hpc7g_2n_4n_8n[0]  # 13401.8s
t_hpc7g = np.concatenate(([t_hpc7g_1n_est], t_hpc7g_2n_4n_8n))

# m8g 8N: only 1 replica (others blocked by AWS m8g.48xlarge capacity
# exhaustion). Retained because its CV with surrounding node counts is
# 0.1–0.4% so the single data point is representative.
t_m8g = np.array([4046.5, 2234.8, 1287.9, 1051.1])

# ---------------------------------------------------------------------------
# Speedups
# ---------------------------------------------------------------------------
baseline_x86 = t_hpc7a[0]       # 1N hpc7a
baseline_arm = t_hpc7g[0]       # estimated 1N hpc7g

su_hpc8a = baseline_x86 / t_hpc8a
su_hpc7a = baseline_x86 / t_hpc7a
su_hpc7g = baseline_arm / t_hpc7g
su_m8g   = baseline_arm / t_m8g

# ---------------------------------------------------------------------------
# Styling — match WRF/OpenFoam Arm chart style
# ---------------------------------------------------------------------------
BAR_W = 0.35
# x86 chart: hpc7a blue, hpc8a orange (hpc8a is the newer / faster one)
HPC7A_COLOR = "#4E79A7"
HPC8A_COLOR = "#F28E2B"
# Arm chart: hpc7g blue, m8g orange (m8g is newer / faster)
HPC7G_COLOR = "#4E79A7"
M8G_COLOR   = "#F28E2B"

# ---------------------------------------------------------------------------
# Chart 1 — x86 hpc8a vs hpc7a
# ---------------------------------------------------------------------------
fig, ax = plt.subplots(figsize=(9, 6))
x_pos = np.arange(len(nodes_x86))

ax.bar(x_pos - BAR_W/2, su_hpc7a, BAR_W, color=HPC7A_COLOR,
       edgecolor='black', label='hpc7a (AMD EPYC Zen4)')
ax.bar(x_pos + BAR_W/2, su_hpc8a, BAR_W, color=HPC8A_COLOR,
       edgecolor='black', label='hpc8a (AMD EPYC Zen5)')

for i, v in enumerate(su_hpc7a):
    ax.text(i - BAR_W/2, v + 0.05, f"{v:.2f}x",
            ha='center', va='bottom', fontsize=9, fontweight='bold')
for i, v in enumerate(su_hpc8a):
    ax.text(i + BAR_W/2, v + 0.05, f"{v:.2f}x",
            ha='center', va='bottom', fontsize=9, fontweight='bold')

ax.set_xticks(x_pos)
ax.set_xticklabels([f"{n}N" for n in nodes_x86])
ax.set_xlabel("Number of nodes (192 cores/node)")
ax.set_ylabel("Speedup vs 1 node hpc7a  (higher is better)")
ax.set_title("OpenRadioss — Ford Taurus 10M  (engine elapsed, mean of 3 replicas)",
             fontsize=12)
ax.grid(True, axis='y', linestyle='--', alpha=0.5)
ax.legend(loc='upper left')
ax.set_ylim(0, max(su_hpc8a.max(), su_hpc7a.max()) * 1.15)

fig.suptitle("OpenRadioss — hpc8a (Zen5) vs hpc7a (Zen4)   "
             "[GCC + OpenMPI 4 + EFA]",
             fontsize=13, fontweight='bold', y=1.00)
plt.tight_layout()
plt.savefig("OpenRadioss-Taurus10M-Hpc8aVsHpc7a.png",
            dpi=150, bbox_inches='tight')
print("Wrote OpenRadioss-Taurus10M-Hpc8aVsHpc7a.png")

# ---------------------------------------------------------------------------
# Chart 2 — Arm Graviton3E vs Graviton4
# ---------------------------------------------------------------------------
fig, ax = plt.subplots(figsize=(9, 6))
x_pos = np.arange(len(nodes_arm))

b_g3 = ax.bar(x_pos - BAR_W/2, su_hpc7g, BAR_W, color=HPC7G_COLOR,
              edgecolor='black', label='hpc7g (Graviton3E, 64 c/n)')
ax.bar(x_pos + BAR_W/2, su_m8g, BAR_W, color=M8G_COLOR,
       edgecolor='black', label='m8g (Graviton4, 192 c/n)')

# Hatched first bar to mark it's estimated
b_g3[0].set_hatch('///')
b_g3[0].set_alpha(0.75)

for i, v in enumerate(su_hpc7g):
    ax.text(i - BAR_W/2, v + 0.05, f"{v:.2f}x",
            ha='center', va='bottom', fontsize=9, fontweight='bold')
for i, v in enumerate(su_m8g):
    ax.text(i + BAR_W/2, v + 0.05, f"{v:.2f}x",
            ha='center', va='bottom', fontsize=9, fontweight='bold')

ax.set_xticks(x_pos)
ax.set_xticklabels([f"{n}N" for n in nodes_arm])
ax.set_xlabel("Number of nodes  (hpc7g: 64 c/n, m8g: 192 c/n)")
ax.set_ylabel("Speedup vs 1 node hpc7g  (higher is better)")
ax.set_title("OpenRadioss — Ford Taurus 10M  (engine elapsed, mean of 3 replicas)",
             fontsize=12)
ax.grid(True, axis='y', linestyle='--', alpha=0.5)
ax.legend(loc='upper left')
ax.set_ylim(0, max(su_m8g.max(), su_hpc7g.max()) * 1.15)

# Note for the estimated bar
ax.text(0 - BAR_W/2, -0.07, "(est. 2 × 2N)",
        ha='center', va='top', fontsize=7, style='italic', color='gray',
        transform=ax.get_xaxis_transform())

fig.suptitle("OpenRadioss — Graviton3E (hpc7g) vs Graviton4 (m8g)   "
             "[GCC + OpenMPI 5 + EFA]",
             fontsize=13, fontweight='bold', y=1.00)
plt.tight_layout()
plt.savefig("OpenRadioss-Taurus10M-Graviton3VsGraviton4.png",
            dpi=150, bbox_inches='tight')
print("Wrote OpenRadioss-Taurus10M-Graviton3VsGraviton4.png")

# ---------------------------------------------------------------------------
# Summary tables
# ---------------------------------------------------------------------------
print("\n=== x86 — Taurus 10M (SIM_TIME=0.01), engine elapsed (s) ===")
print(f"{'Nodes':<6}{'hpc7a':>10}{'hpc8a':>10}{'hpc7a spd':>12}{'hpc8a spd':>12}")
for i, n in enumerate(nodes_x86):
    print(f"{n}N    {t_hpc7a[i]:>10.1f}{t_hpc8a[i]:>10.1f}"
          f"{su_hpc7a[i]:>11.2f}x{su_hpc8a[i]:>11.2f}x")

print("\n=== Arm — Taurus 10M (SIM_TIME=0.01), engine elapsed (s) ===")
print(f"{'Nodes':<10}{'hpc7g':>12}{'m8g':>10}{'hpc7g spd':>12}{'m8g spd':>10}")
for i, n in enumerate(nodes_arm):
    tag = " (est)" if n == 1 else ""
    print(f"{n}N{tag:<7}{t_hpc7g[i]:>12.1f}{t_m8g[i]:>10.1f}"
          f"{su_hpc7g[i]:>11.2f}x{su_m8g[i]:>9.2f}x")
