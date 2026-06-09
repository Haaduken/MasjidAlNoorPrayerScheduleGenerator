#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./generate_prayer_pdf.sh <month_number>

Arguments:
  month_number   Gregorian month number (1-12)

Environment variables:
  YEAR           Year to use in the IslamicFinder URL (defaults to 2026)
  CITY_URL       Full IslamicFinder print URL to use instead of generated URL

Example:
  ./generate_prayer_pdf.sh 5
  YEAR=2026 ./generate_prayer_pdf.sh 5
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

MONTH_INDEX="$1"
if ! [[ "$MONTH_INDEX" =~ ^[0-9]+$ ]] || (( MONTH_INDEX < 1 || MONTH_INDEX > 12 )); then
  echo "Error: month_number must be an integer from 1 to 12." >&2
  exit 1
fi

if ! command -v chromium >/dev/null 2>&1; then
  echo "Error: 'chromium' is required but not found in PATH." >&2
  echo "Install Chromium or adjust the script to use your Chrome binary." >&2
  exit 1
fi

if ! command -v pdftotext >/dev/null 2>&1; then
  echo "Error: 'pdftotext' is required but not found in PATH." >&2
  echo "Install poppler-utils (or equivalent) and rerun." >&2
  exit 1
fi

if ! command -v pdflatex >/dev/null 2>&1; then
  echo "Error: 'pdflatex' is required but not found in PATH." >&2
  echo "Install TeX Live and rerun." >&2
  exit 1
fi

YEAR="${YEAR:-2026}"
GREG_MONTH=$MONTH_INDEX
URL_MONTH_INDEX=$((MONTH_INDEX - 1))
MONTH_PADDED=$(printf '%02d' "$GREG_MONTH")
OUTPUT_FILE="prayer-schedule-${YEAR}-${MONTH_PADDED}.pdf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_PATH="${LOGO_PATH:-$SCRIPT_DIR/MCO-Logo-Color.png}"

if [[ -n "${CITY_URL:-}" ]]; then
  URL="$CITY_URL"
else
  URL="https://www.islamicfinder.org/prayer-times/printmonthlyprayer/?timeInterval=month&month=${URL_MONTH_INDEX}&year=${YEAR}&calendarType=Gregorian"
fi

echo "Fetching prayer data from: $URL"

# Use an isolated browser profile for deterministic headless output.
PROFILE_DIR=$(mktemp -d)
TMP_DIR=$(mktemp -d)
cleanup() {
  if [[ "${KEEP_TMP:-0}" == "1" ]]; then
    echo "Keeping temp files in: $TMP_DIR"
    return
  fi
  rm -rf "$PROFILE_DIR" "$TMP_DIR"
}
trap cleanup EXIT

RAW_PDF="$TMP_DIR/source.pdf"
RAW_TXT="$TMP_DIR/source.txt"
ROWS_TSV="$TMP_DIR/rows.tsv"
TEX_FILE="$TMP_DIR/schedule.tex"
LOGO_TEX="$TMP_DIR/mco-logo.png"

if [[ -f "$LOGO_PATH" ]]; then
  cp "$LOGO_PATH" "$LOGO_TEX"
else
  LOGO_TEX=""
fi

chromium \
  --headless \
  --disable-gpu \
  --no-sandbox \
  --user-data-dir="$PROFILE_DIR" \
  --user-agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' \
  --window-size=1280,2200 \
  --virtual-time-budget=120000 \
  --print-to-pdf-no-header \
  --print-to-pdf="$RAW_PDF" \
  "$URL" >/dev/null 2>&1

if [[ ! -s "$RAW_PDF" ]]; then
  echo "Error: failed to fetch source PDF from IslamicFinder." >&2
  exit 1
fi

if strings "$RAW_PDF" | grep -q '403 Forbidden'; then
  echo "Error: IslamicFinder returned 403 Forbidden to automated access from this network." >&2
  echo "Try one of these options:" >&2
  echo "  1) Run from a normal residential network/browser environment" >&2
  echo "  2) Provide CITY_URL with a full city-specific print URL if available" >&2
  exit 2
fi

pdftotext "$RAW_PDF" "$RAW_TXT"

awk '
function is_time(s) { return s ~ /^[0-9]{2}:[0-9]{2} [AP]M$/ }
function full_day(abbr) {
  if (abbr == "Mon") return "MONDAY"
  if (abbr == "Tue") return "TUESDAY"
  if (abbr == "Wed") return "WEDNESDAY"
  if (abbr == "Thu") return "THURSDAY"
  if (abbr == "Fri") return "FRIDAY"
  if (abbr == "Sat") return "SATURDAY"
  if (abbr == "Sun") return "SUNDAY"
  return toupper(abbr)
}
{
  gsub(/\r/, "")
  line = $0
  sub(/^[[:space:]]+/, "", line)
  sub(/[[:space:]]+$/, "", line)
  if (line != "") t[++n] = line
}
END {
  for (i = 1; i <= n - 8; i++) {
    if (t[i] ~ /^[0-9]{1,2}$/ &&
        t[i+1] ~ /^[0-9]{1,2}$/ &&
        t[i+2] ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ &&
        is_time(t[i+3]) && is_time(t[i+4]) && is_time(t[i+5]) &&
        is_time(t[i+6]) && is_time(t[i+7]) && is_time(t[i+8])) {
      print full_day(t[i+2]) "\t" (t[i+1] + 0) "\t" (t[i] + 0) "\t" \
            t[i+3] "\t" t[i+4] "\t" t[i+5] "\t" \
            t[i+6] "\t" t[i+7] "\t" t[i+8]
      i += 8
    }
  }
}
' "$RAW_TXT" > "$ROWS_TSV"

if [[ ! -s "$ROWS_TSV" ]]; then
  echo "Error: could not parse prayer rows from fetched data." >&2
  exit 3
fi

ROW_COUNT=$(wc -l < "$ROWS_TSV")
if (( ROW_COUNT < 25 )); then
  echo "Error: parsed only $ROW_COUNT rows; expected a full month." >&2
  exit 4
fi

# Tune table density by month length so the schedule fills one page cleanly.
TABLE_STRETCH="1.5"
TABLE_SIZE_CMD="\\large"
if (( ROW_COUNT <= 29 )); then
  TABLE_STRETCH="1.5"
  TABLE_SIZE_CMD="\\Large"
fi

GREGORIAN_LABEL=$(grep -E '^[A-Za-z]+ [0-9]{4}$' "$RAW_TXT" | head -n 1)
HIJRI_LABEL=$(grep -E "^[A-Za-z' -]+[0-9]{4} - [A-Za-z' -]+[0-9]{4}$" "$RAW_TXT" | head -n 1)

if [[ -z "$GREGORIAN_LABEL" ]]; then
  GREGORIAN_LABEL=$(date -d "$YEAR-$MONTH_PADDED-01" '+%B %Y')
fi

if [[ -z "$HIJRI_LABEL" ]]; then
  HIJRI_LABEL="Hijri Month"
fi

MONTH_ABBR=$(date -d "$YEAR-$MONTH_PADDED-01" '+%b' | tr '[:lower:]' '[:upper:]')

minus_three_minutes() {
  local hm12="$1"
  local h m ap h24 total out24 outm outap outh
  if [[ ! "$hm12" =~ ^([0-9]{1,2}):([0-9]{2})\ ([AP]M)$ ]]; then
    echo "$hm12"
    return
  fi

  h="${BASH_REMATCH[1]}"
  m="${BASH_REMATCH[2]}"
  ap="${BASH_REMATCH[3]}"

  h24=$((10#$h % 12))
  if [[ "$ap" == "PM" ]]; then
    h24=$((h24 + 12))
  fi

  total=$((h24 * 60 + 10#$m - 3))
  if (( total < 0 )); then
    total=0
  fi

  out24=$((total / 60))
  outm=$((total % 60))
  if (( out24 >= 12 )); then
    outap="PM"
  else
    outap="AM"
  fi
  outh=$((out24 % 12))
  if (( outh == 0 )); then
    outh=12
  fi
  printf '%d:%02d %s' "$outh" "$outm" "$outap"
}

if [[ -n "$LOGO_TEX" ]]; then
  LOGO_LATEX="\\includegraphics[width=0.95\\linewidth]{$LOGO_TEX}"
  WATERMARK_LATEX="\\AddToShipoutPictureBG*{\\begin{tikzpicture}[remember picture,overlay]\\node[opacity=0.14] at (current page.center) {\\includegraphics[width=0.62\\paperwidth]{$LOGO_TEX}};\\end{tikzpicture}}"
else
  LOGO_LATEX="\\rule{1.2in}{0.55in}"
  WATERMARK_LATEX=""
fi

{
  cat <<EOF
\\documentclass[10pt]{article}
\usepackage[margin=0.22in]{geometry}
\\usepackage[table]{xcolor}
\usepackage{graphicx}
\usepackage{tikz}
\usepackage{eso-pic}
\\usepackage{array}
\\usepackage{helvet}
\\renewcommand{\\familydefault}{\\sfdefault}
\\pagestyle{empty}
\\setlength{\\parindent}{0pt}
\\definecolor{headergreen}{HTML}{088E38}
\\definecolor{daygreen}{HTML}{0A9B42}
\\definecolor{rowlight}{HTML}{EFF7EF}
\\definecolor{suncol}{HTML}{FBE4E4}
\\definecolor{gridgreen}{HTML}{1A8F43}
\\arrayrulecolor{gridgreen}
\\begin{document}
${WATERMARK_LATEX}
\noindent
\begin{minipage}[c]{0.18\textwidth}
\centering
${LOGO_LATEX}
\end{minipage}
\hfill
\begin{minipage}[c]{0.79\textwidth}
\centering
{\fontsize{12}{14}\selectfont\textbf{IN THE NAME OF ALLAH, THE MOST GRACIOUS, THE MOST MERCIFUL}}\\\\[2pt]
{\fontsize{10}{12}\selectfont\textbf{MUSLIM COMMUNITY ORGANIZATION / MASJID NOOR}}\\\\[1pt]
{\fontsize{9}{11}\selectfont\textbf{1117 42ND ST. DES MOINES, IA 50311}}\\\\[1pt]
{\fontsize{9}{11}\selectfont\textbf{PHONE: 515.274.4626  WEB: DMMCO.ORG  E-MAIL: INFO@DMMCO.ORG}}
\end{minipage}

\vspace{4pt}
\noindent\rule{\textwidth}{0.6pt}

\vspace{6pt}
\\begin{center}
{\fontsize{13}{15}\selectfont\textbf{PRAYER SCHEDULE FOR THE MONTH OF ${HIJRI_LABEL}}}\\\\[2pt]
{\normalsize\textbf{(${GREGORIAN_LABEL})}}\\\\[8pt]
\renewcommand{\arraystretch}{${TABLE_STRETCH}}
\setlength{\tabcolsep}{2.2pt}
${TABLE_SIZE_CMD}
\resizebox{\textwidth}{!}{%
\begin{tabular}{|*{10}{>{\centering\arraybackslash}p{0.95in}|}}
\\hline
\\rowcolor{headergreen}
\\textcolor{white}{\\textbf{DAY}} &
\\textcolor{white}{\\textbf{LUNAR}} &
\\textcolor{white}{\\textbf{SOLAR}} &
\\textcolor{white}{\\textbf{FAJIR}} &
\\textcolor{white}{\\textbf{SUNRISE}} &
\\textcolor{white}{\\textbf{ZUHR}} &
\\textcolor{white}{\\textbf{ASR}} &
\\textcolor{white}{\\textbf{SUNSET}} &
\\textcolor{white}{\\textbf{MAGRIB}} &
\\textcolor{white}{\\textbf{ISHA}} \\\\ \hline
EOF

  row_num=0
  while IFS=$'\t' read -r day lunar solar fajr sunrise zuhr asr magrib isha; do
    row_num=$((row_num + 1))
    sunset=$(minus_three_minutes "$magrib")
    solar_label="${solar}-${MONTH_ABBR}"
    if (( row_num % 2 == 0 )); then
      echo "\\rowcolor{rowlight}"
    fi
    printf '\\cellcolor{daygreen}\\textcolor{white}{\\normalsize\\textbf{%s}} & %s & %s & %s & \\cellcolor{suncol}%s & %s & %s & \\cellcolor{suncol}%s & %s & %s \\\\ \\hline\n' \
      "$day" "$lunar" "$solar_label" "$fajr" "$sunrise" "$zuhr" "$asr" "$sunset" "$magrib" "$isha"
  done < "$ROWS_TSV"

  cat <<'EOF'
\end{tabular}
}
\vfill

{\small\textbf{ESTABLISH REGULAR PRAYERS (SALAAT): FOR SUCH PRAYERS ARE ENJOINED BY BELIEVERS AT FIXED TIMES. (NISSA:103)}}
\end{center}
\end{document}
EOF
} > "$TEX_FILE"

pdflatex -interaction=nonstopmode -halt-on-error -output-directory "$TMP_DIR" "$TEX_FILE"
cp "$TMP_DIR/schedule.pdf" "$OUTPUT_FILE"

echo "Created: $OUTPUT_FILE"
