#!/usr/bin/env python3
"""Summarize a main.nf run: coverage track + PASS variants -> example_results/.

Usage: python scripts/summarize_run.py [results_dir] [out_dir]
Needs samtools on PATH (or use the GATK/samtools containers) and matplotlib.
"""
import gzip, subprocess, sys
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

res = Path(sys.argv[1] if len(sys.argv) > 1 else "results")
out = Path(sys.argv[2] if len(sys.argv) > 2 else "example_results")
out.mkdir(exist_ok=True)

depth = subprocess.run(["samtools", "depth", "-a", str(res / "dedup/sample1.dedup.bam")],
                       capture_output=True, text=True, check=True).stdout.split("\n")
pos, cov = zip(*[(int(l.split("\t")[1]), int(l.split("\t")[2])) for l in depth if l])

variants = []
with gzip.open(res / "filtered/sample1.filtered.vcf.gz", "rt") as fh:
    for l in fh:
        if l.startswith("#"):
            continue
        f = l.rstrip("\n").split("\t")
        variants.append((int(f[1]), f[3], f[4], float(f[5]), f[9].split(":")[0]))

with open(out / "variants_summary.tsv", "w") as fh:
    fh.write("pos\tref\talt\tqual\tgenotype\n")
    for v in variants:
        fh.write("\t".join(map(str, v)) + "\n")

genes = {"ORF1ab": (266, 21555), "S": (21563, 25384), "ORF3a-M": (25393, 26883),
         "N": (28274, 29533)}
fig, ax = plt.subplots(figsize=(11, 3.6))
ax.fill_between(pos, cov, step="mid", color="#4c72b0", alpha=0.8, lw=0)
ax.set_yscale("symlog", linthresh=1)
for p, ref, alt, q, gt in variants:
    ax.axvline(p, color="#c44e52", lw=0.8, alpha=0.7)
for g, (a, b) in genes.items():
    ax.axvspan(a, b, ymin=0, ymax=0.04, color="k", alpha=0.35)
    ax.text((a + b) / 2, 0.06, g, transform=ax.get_xaxis_transform(), ha="center", fontsize=8)
ax.set_xlabel("NC_045512.2 position (bp)")
ax.set_ylabel("depth after dedup")
ax.set_title(f"SARS-CoV-2 ERR10730304: coverage and {len(variants)} PASS variants (red)")
fig.tight_layout()
fig.savefig(out / "coverage_variants.png", dpi=130)
print(f"{len(variants)} PASS variants; mean depth {sum(cov)/len(cov):.1f}; "
      f"{sum(c > 0 for c in cov) / len(cov):.1%} of genome covered")
