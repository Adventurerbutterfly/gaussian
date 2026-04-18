#!/usr/bin/env bash
set -euo pipefail

# Input: imaginary log list (one log path per line) 1:-imag_files.txt bir dosya verlimemişse imag_files.txt çalıştırıyor
LIST="${1:-imag_files.txt}"

# Output
OUTROOT="reopt_inputs"
JOBLIST="joblist_reopt.txt"
REPORT="reopt_report.tsv"

# thresholds (cm^-1)
EASY_TH=-20
MED_TH=-50

if [ ! -f "$LIST" ]; then
  echo "[ERR] List not found: $LIST"
  exit 1
fi

mkdir -p "$OUTROOT"
: > "$JOBLIST"
: > "$REPORT"

# --- function: get most negative frequency from a log (returns "NA" if none) ---
minfreq_from_log() {
  awk '
    /Frequencies --/{
      for(i=3;i<=NF;i++){
        v=$i+0
        if(min=="" || v<min) min=v
      }
    }
    END{
      if(min=="") print "NA";
      else printf "%.2f", min
    }' "$1"
}

# --- function: patch route line and chk in .com ---
patch_com() {
  local infile="$1"     # original .com
  local outfile="$2"    # new .com
  local newchk="$3"     # chk filename only (no path)
  local opt_add="$4"    # e.g. "calcfc,tight,maxstep=5"
  local scf_add="$5"    # e.g. "xqc,tight,maxcycle=512"
  local add_ultra="$6"  # "yes" or "no"

  export NEWCHK="$newchk"
  export OPTADD="$opt_add"
  export SCFADD="$scf_add"
  export ADDULTRA="$add_ultra"

  perl -0777 -pe '
    my $newchk = $ENV{NEWCHK};
    my $optadd = $ENV{OPTADD};
    my $scfadd = $ENV{SCFADD};
    my $addultra = $ENV{ADDULTRA};

    # %chk line update (if missing, add at top)
    if ($$_ =~ /^\s*%chk\s*=/m) {
      $$_ =~ s/^\s*%chk\s*=.*$/%chk=$newchk/m;
    } else {
      $$_ = "%chk=$newchk\n" . $$_;
    }

    # find first route line starting with #
    if ($$_ =~ /^(\s*#.*)$/m) {
      my $route = $1;
      my $new = $route;

      # --- OPT merge ---
      if ($new =~ /\bopt\s*=\s*\(([^)]*)\)/i) {
        my $inside = $1;
        my @o = map { s/^\s+|\s+$//gr } split(/\s*,\s*/, $inside);
        my %seen; @o = grep { $_ ne "" && !$seen{lc($_)}++ } @o;

        for my $x (split(/\s*,\s*/, $optadd)) {
          push @o, $x unless grep { lc($_) eq lc($x) } @o;
        }
        my $joined = join(",", @o);
        $new =~ s/\bopt\s*=\s*\(([^)]*)\)/opt=($joined)/i;
      } elsif ($new =~ /\bopt\b/i) {
        $new =~ s/\bopt\b/opt=($optadd)/i;
      } else {
        $new .= " opt=($optadd)";
      }

      # --- SCF merge ---
      if ($new =~ /\bscf\s*=\s*\(([^)]*)\)/i) {
        my $inside = $1;
        my @s = map { s/^\s+|\s+$//gr } split(/\s*,\s*/, $inside);
        my %seen; @s = grep { $_ ne "" && !$seen{lc($_)}++ } @s;

        for my $x (split(/\s*,\s*/, $scfadd)) {
          push @s, $x unless grep { lc($_) eq lc($x) } @s;
        }
        my $joined = join(",", @s);
        $new =~ s/\bscf\s*=\s*\(([^)]*)\)/scf=($joined)/i;
      } elsif ($new =~ /\bscf\s*=\s*([^\s]+)/i) {
        my $val = $1;
        my @s = map { s/^\s+|\s+$//gr } split(/\s*,\s*/, $val);
        my %seen; @s = grep { $_ ne "" && !$seen{lc($_)}++ } @s;

        for my $x (split(/\s*,\s*/, $scfadd)) {
          push @s, $x unless grep { lc($_) eq lc($x) } @s;
        }
        my $joined = join(",", @s);
        $new =~ s/\bscf\s*=\s*\Q$val\E/scf=($joined)/i;
      } else {
        $new .= " scf=($scfadd)";
      }

      # --- add ultrafine if requested and not already present ---
      if ($addultra eq "yes") {
        if ($new !~ /\bint\s*=\s*ultrafine\b/i && $new !~ /\bultrafine\b/i) {
          $new .= " int=ultrafine";
        }
      }

      # replace only first route line
      $$_ =~ s/^\Q$route\E$/$new/m;
    }

    $$_;
  ' "$infile" > "$outfile"
}

echo -e "class\tminfreq\tlog\tcom_out" >> "$REPORT"

while IFS= read -r logpath; do
  [[ -z "${logpath// }" ]] && continue
  [[ "$logpath" =~ ^# ]] && continue

  if [ ! -f "$logpath" ]; then
    echo "[WARN] Missing log: $logpath"
    continue
  fi

  minf="$(minfreq_from_log "$logpath")"
  if [ "$minf" = "NA" ]; then
    echo "[WARN] No frequencies in: $logpath"
    continue
  fi

  # only imaginary (minfreq < 0)
  awk_check=$(awk -v x="$minf" 'BEGIN{ if(x<0) print 1; else print 0 }')
  if [ "$awk_check" -ne 1 ]; then
    continue
  fi

  # classify
  cls="EASY"
  # compare numerically
  hard=$(awk -v x="$minf" -v th="$MED_TH" 'BEGIN{print (x<th)?1:0}')
  med=$(awk -v x="$minf" -v th1="$MED_TH" -v th2="$EASY_TH" 'BEGIN{print (x>=th1 && x<th2)?1:0}')
  easy=$(awk -v x="$minf" -v th="$EASY_TH" 'BEGIN{print (x>=th && x<0)?1:0}')

  if [ "$hard" -eq 1 ]; then
    cls="HARD"
    opt_add="calcfc,tight,maxstep=5"
    scf_add="xqc,tight,maxcycle=512"
  elif [ "$med" -eq 1 ]; then
    cls="MED"
    opt_add="calcfc,tight"
    scf_add="xqc,tight,maxcycle=512"
  else
    cls="EASY"
    opt_add="calcfc,tight"
    scf_add="xqc,tight"
  fi

  # map log -> com
  compath="${logpath%.log}.com"
  if [ ! -f "$compath" ]; then
    echo "[WARN] COM not found for: $logpath"
    echo "       expected: $compath"
    continue
  fi

  # output path under OUTROOT preserving directory structure
  rel="${compath#/}"
  outcom="$OUTROOT/$rel"
  outdir="$(dirname "$outcom")"
  mkdir -p "$outdir"

  stem="$(basename "$compath" .com)"
  newchk="${stem}_reopt.chk"

  patch_com "$compath" "$outcom" "$newchk" "$opt_add" "$scf_add" "yes"

  echo "$outcom" >> "$JOBLIST"
  echo -e "${cls}\t${minf}\t${logpath}\t${outcom}" >> "$REPORT"
  echo "[OK] $cls  minfreq=$minf  -> $outcom"

done < "$LIST"

echo
echo "[DONE] reopt inputs: $(wc -l < "$JOBLIST")"
echo "       joblist: $JOBLIST"
echo "       report : $REPORT"
