#!/usr/bin/env bash
set -euo pipefail

# Tarama yapılacak kök klasörler
DIRS=(gaussian_HA gaussian_Aminus gaussian_common)

# Çıktı dosyaları
OUT_LOGS="imag_logs.txt"
OUT_COMS="joblist_imag_coms.txt"
OUT_TSV="imag_summary.tsv"

: > "$OUT_LOGS"
: > "$OUT_COMS"
: > "$OUT_TSV"

echo -e "NImag\tminfreq\tlog\tcom" >> "$OUT_TSV"

is_normal_done() {
  # normal termination varsa 0 döndür
  grep -q "Normal termination" "$1"
}

get_nimag() {
  # Son NImag değerini al (yoksa boş)
  grep -o "NImag=[0-9]\+" "$1" 2>/dev/null | tail -n1 | cut -d= -f2 || true
}

get_minfreq() {
  # Frekans bloklarındaki en küçük (en negatif) frekansı bul (yoksa NA)
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

total_logs=0
done_logs=0
imag_count=0
missing_com=0

# tüm logları dolaş
while IFS= read -r log; do
  [ -f "$log" ] || continue
  total_logs=$((total_logs+1))

  if is_normal_done "$log"; then
    done_logs=$((done_logs+1))
  else
    # bitmemiş logları istersen skip et; burada skip ediyoruz
    continue
  fi

  nimag="$(get_nimag "$log")"
  [ -z "${nimag:-}" ] && nimag="NA"

  minf="$(get_minfreq "$log")"

  # Imaginary kriteri:
  # 1) NImag sayısal ve >0 ise
  # 2) NImag yoksa minfreq < 0 ise
  imag=0
  if [[ "$nimag" != "NA" ]]; then
    if [ "$nimag" -gt 0 ]; then imag=1; fi
  else
    if [[ "$minf" != "NA" ]] && awk -v x="$minf" 'BEGIN{exit !(x<0)}'; then
      imag=1
      nimag=0
    fi
  fi

  if [ "$imag" -eq 1 ]; then
    compath="${log%.log}.com"
    echo "$log" >> "$OUT_LOGS"

    if [ -f "$compath" ]; then
      echo "$compath" >> "$OUT_COMS"
    else
      missing_com=$((missing_com+1))
    fi

    echo -e "${nimag}\t${minf}\t${log}\t${compath}" >> "$OUT_TSV"
    imag_count=$((imag_count+1))
  fi

done < <(find "${DIRS[@]}" -type f -name "*.log" 2>/dev/null | sort)

echo "[DONE] total_logs=$total_logs  normal_done=$done_logs  imaginary=$imag_count"
echo "[OUT]  $OUT_LOGS"
echo "[OUT]  $OUT_COMS"
echo "[OUT]  $OUT_TSV"
if [ "$missing_com" -gt 0 ]; then
  echo "[WARN] $missing_com adet log için .com bulunamadı (OUT_TSV'de com path var)."
fi
