#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./pipeline_reopt_submit.sh [PARALLEL] [IMAG_LIST] [SBATCH]
# Defaults:
PARALLEL="${1:-2}"
IMAG_LIST="${2:-imag_files.txt}"
SBATCH="${3:-g16_path.sbatch}"

OUTROOT="reopt_inputs"
JOBLIST="joblist_reopt.txt"
REPORT="reopt_report.tsv"

# thresholds (cm^-1)
EASY_TH=-20
MED_TH=-50

if [ ! -f "$IMAG_LIST" ]; then
  echo "[ERR] imaginary list not found: $IMAG_LIST"
  exit 1
fi
if [ ! -f "$SBATCH" ]; then
  echo "[ERR] sbatch script not found: $SBATCH"
  exit 1
fi

mkdir -p "$OUTROOT"
: > "$JOBLIST"
: > "$REPORT"
echo -e "class\tminfreq\tlog\tcom_out" >> "$REPORT"

minfreq_from_log() {
  awk '
    /Frequencies --/{
      for(i=3;i<=NF;i++){ v=$i+0; if(min=="" || v<min) min=v }
    }
    END{ if(min=="") print "NA"; else printf "%.2f", min }' "$1"
}

patch_com() {
  local infile="$1" outfile="$2" newchk="$3" opt_add="$4" scf_add="$5"
  export NEWCHK="$newchk" OPTADD="$opt_add" SCFADD="$scf_add"

  perl -0777 -pe '
    my $newchk=$ENV{NEWCHK};
    my $optadd=$ENV{OPTADD};
    my $scfadd=$ENV{SCFADD};

    # %chk
    if ($$_ =~ /^\s*%chk\s*=/m) { $$_ =~ s/^\s*%chk\s*=.*$/%chk=$newchk/m; }
    else { $$_ = "%chk=$newchk\n" . $$_; }

    # first route line
    if ($$_ =~ /^(\s*#.*)$/m) {
      my $route=$1; my $new=$route;

      # OPT merge
      if ($new =~ /\bopt\s*=\s*\(([^)]*)\)/i) {
        my @o=split(/\s*,\s*/, $1); my %s; @o=grep{$_ ne "" && !$s{lc($_)}++}@o;
        for my $x (split(/\s*,\s*/, $optadd)) { push @o,$x unless grep{lc($_) eq lc($x)}@o; }
        my $j=join(",",@o);
        $new =~ s/\bopt\s*=\s*\(([^)]*)\)/opt=($j)/i;
      } elsif ($new =~ /\bopt\b/i) { $new =~ s/\bopt\b/opt=($optadd)/i; }
      else { $new .= " opt=($optadd)"; }

      # SCF merge
      if ($new =~ /\bscf\s*=\s*\(([^)]*)\)/i) {
        my @s=split(/\s*,\s*/, $1); my %h; @s=grep{$_ ne "" && !$h{lc($_)}++}@s;
        for my $x (split(/\s*,\s*/, $scfadd)) { push @s,$x unless grep{lc($_) eq lc($x)}@s; }
        my $j=join(",",@s);
        $new =~ s/\bscf\s*=\s*\(([^)]*)\)/scf=($j)/i;
      } elsif ($new =~ /\bscf\s*=\s*([^\s]+)/i) {
        my $val=$1;
        my @s=split(/\s*,\s*/, $val); my %h; @s=grep{$_ ne "" && !$h{lc($_)}++}@s;
        for my $x (split(/\s*,\s*/, $scfadd)) { push @s,$x unless grep{lc($_) eq lc($x)}@s; }
        my $j=join(",",@s);
        $new =~ s/\bscf\s*=\s*\Q$val\E/scf=($j)/i;
      } else { $new .= " scf=($scfadd)"; }

      # add int=ultrafine if not present
      if ($new !~ /\bint\s*=\s*ultrafine\b/i && $new !~ /\bultrafine\b/i) {
        $new .= " int=ultrafine";
      }

      $$_ =~ s/^\Q$route\E$/$new/m;
    }
    $$_;
  ' "$infile" > "$outfile"
}

echo "[STEP1] Build reopt inputs + joblist from: $IMAG_LIST"

while IFS= read -r logpath; do
  [[ -z "${logpath// }" ]] && continue
  [[ "$logpath" =~ ^# ]] && continue
  [[ "$logpath" != *.log ]] && continue

  if [ ! -f "$logpath" ]; then
    echo "[WARN] Missing log: $logpath"
    continue
  fi

  minf="$(minfreq_from_log "$logpath")"
  [ "$minf" != "NA" ] || { echo "[WARN] No freq in: $logpath"; continue; }
  awk -v x="$minf" 'BEGIN{exit !(x<0)}' || continue

  # classify by minfreq
  if awk -v x="$minf" -v th="$MED_TH" 'BEGIN{exit !(x<th)}'; then
    cls="HARD"; opt_add="calcfc,tight,maxstep=5"; scf_add="xqc,tight,maxcycle=512"
  elif awk -v x="$minf" -v th1="$MED_TH" -v th2="$EASY_TH" 'BEGIN{exit !(x>=th1 && x<th2)}'; then
    cls="MED";  opt_add="calcfc,tight";            scf_add="xqc,tight,maxcycle=512"
  else
    cls="EASY"; opt_add="calcfc,tight";            scf_add="xqc,tight"
  fi

  compath="${logpath%.log}.com"
  if [ ! -f "$compath" ]; then
    echo "[WARN] COM not found for: $logpath"
    echo "       expected: $compath"
    continue
  fi

  rel="${compath#/}"
  outcom="$OUTROOT/$rel"
  mkdir -p "$(dirname "$outcom")"

  stem="$(basename "$compath" .com)"
  newchk="${stem}_reopt.chk"

  patch_com "$compath" "$outcom" "$newchk" "$opt_add" "$scf_add"

  echo "$outcom" >> "$JOBLIST"
  echo -e "${cls}\t${minf}\t${logpath}\t${outcom}" >> "$REPORT"
  echo "[OK] $cls minfreq=$minf -> $outcom"
done < "$IMAG_LIST"

N=$(wc -l < "$JOBLIST" | tr -d ' ')
echo "[STEP1 DONE] joblist=$JOBLIST (N=$N)"
echo "[REPORT] $REPORT"

if [ "$N" -eq 0 ]; then
  echo "[ERR] joblist boş. imag list doğru mu?"
  exit 1
fi

echo "[STEP2] Submit reopt array with max-parallel=%$PARALLEL"
RID=$(sbatch --parsable --array=1-"$N"%${PARALLEL} "$SBATCH" "$JOBLIST")
echo "[OK] Submitted reopt array JOBID=$RID"
echo "$RID" > reopt_array_jobid.txt
