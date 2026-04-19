#!/bin/bash
#SBATCH --job-name=finalize_qrc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=01:00:00
#SBATCH --output=slurm_finalize_%j.out

set -euo pipefail

ROOT="reopt_inputs"
GOOD="reopt_good_apply.txt"
BAD="reopt_still_imag.txt"

: > "$GOOD"
: > "$BAD"

echo "[FINAL] scanning reopt logs..."

find "$ROOT" -name "*.log" -exec grep -l "Normal termination" {} \; 2>/dev/null \
| while read -r f; do
    n=$(grep -o "NImag=[0-9]\+" "$f" | tail -n1 | cut -d= -f2); n=${n:-0}
    if [ "$n" -eq 0 ]; then
      echo "$f" >> "$GOOD"
    else
      echo "$f  NImag=$n" >> "$BAD"
    fi
  done

good_n=$(wc -l < "$GOOD" | tr -d ' ')
bad_n=$(wc -l < "$BAD" | tr -d ' ')
echo "[FINAL] good(NImag=0)=$good_n bad(NImag>0)=$bad_n"

# Apply good logs back onto original dirs
while IFS= read -r f; do
  target="${f#${ROOT}/}"     # reopt_inputs/... -> ...
  mkdir -p "$(dirname "$target")"
  cp -f "$f" "$target"
  echo "[APPLY] $f -> $target"
done < "$GOOD"

# If still imaginary, run qrc
if [ "$bad_n" -gt 0 ]; then
  echo "[FINAL] still imaginary -> running qrc_retry_replace_original.py"
  python3 qrc_retry_replace_original.py || true
else
  echo "[FINAL] all fixed -> no qrc needed"
fi

# Optional: rerun pKa extraction with your existing extractor
if [ -f extract_pka_from_logs.py ]; then
  echo "[FINAL] re-running extract_pka_from_logs.py"
  python3 extract_pka_from_logs.py || true
fi

echo "[FINAL] done."
