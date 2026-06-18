#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./generate_prayer_pdf_hijri.sh <hijri_month_number> [hijri_year]

Arguments:
  hijri_month_number   Hijri month number (1-12)
  hijri_year           Optional 4-digit Hijri year (defaults to an approximate current Hijri year)

Environment variables:
  CITY_URL             Full IslamicFinder print URL. If set, script will only use this URL.

Example:
  ./generate_prayer_pdf_hijri.sh 9
  ./generate_prayer_pdf_hijri.sh 9 1447
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# < 1 || $# > 2 )); then
  usage
  exit 1
fi

MONTH_INDEX="$1"
if ! [[ "$MONTH_INDEX" =~ ^[0-9]+$ ]] || (( MONTH_INDEX < 1 || MONTH_INDEX > 12 )); then
  echo "Error: hijri_month_number must be an integer from 1 to 12." >&2
  exit 1
fi

# Approximation: Hijri year ~= (Gregorian year - 622) * 33 / 32.
CURRENT_GREG_YEAR="$(date +%Y)"
DEFAULT_HIJRI_YEAR=$(( (CURRENT_GREG_YEAR - 622) * 33 / 32 ))
YEAR="${2:-$DEFAULT_HIJRI_YEAR}"
if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
  echo "Error: hijri_year must be a 4-digit number (e.g. 1447)." >&2
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

HIJRI_MONTH_NAMES=(
  Muharram
  Safar
  "Rabi Al Awwal"
  "Rabi Al Thani"
  "Jumada Al Ula"
  "Jumada Al Akhirah"
  Rajab
  Shaban
  Ramadan
  Shawwal
  "Dhul Qadah"
  "Dhul Hijjah"
)

HIJRI_MONTH_NAME="${HIJRI_MONTH_NAMES[$((MONTH_INDEX - 1))]}"
MONTH_PADDED=$(printf '%02d' "$MONTH_INDEX")
OUTPUT_FILE="prayer-schedule-hijri-${YEAR}-${MONTH_PADDED}.pdf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_PATH="${LOGO_PATH:-$SCRIPT_DIR/MCO-Logo-Color.png}"

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
COLLECTED_ROWS="$TMP_DIR/collected.tsv"
TEX_FILE="$TMP_DIR/schedule.tex"
LOGO_TEX="$TMP_DIR/mco-logo.png"

if [[ -f "$LOGO_PATH" ]]; then
  cp "$LOGO_PATH" "$LOGO_TEX"
else
  LOGO_TEX=""
fi

fetch_month_pdf_text() {
  local attempt profile_dir ua alt_profile_dir
  ua='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
  alt_profile_dir=""

  for attempt in 1 2; do
    profile_dir="$PROFILE_DIR"
    if (( attempt == 2 )); then
      alt_profile_dir=$(mktemp -d)
      profile_dir="$alt_profile_dir"
      ua='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    fi

    chromium \
      --headless \
      --disable-gpu \
      --no-sandbox \
      --user-data-dir="$profile_dir" \
      --user-agent="$ua" \
      --window-size=1280,2200 \
      --virtual-time-budget=120000 \
      --print-to-pdf-no-header \
      --print-to-pdf="$RAW_PDF" \
      "$URL" >/dev/null 2>&1

    if [[ ! -s "$RAW_PDF" ]]; then
      if [[ -n "$alt_profile_dir" ]]; then
        rm -rf "$alt_profile_dir"
      fi
      continue
    fi

    pdftotext "$RAW_PDF" "$RAW_TXT"

    if strings "$RAW_PDF" | grep -q '403 Forbidden' || rg -q '403 Forbidden' "$RAW_TXT"; then
      if [[ -n "$alt_profile_dir" ]]; then
        rm -rf "$alt_profile_dir"
      fi
      continue
    fi

    if rg -q 'Something went wrong|Sorry!' "$RAW_TXT"; then
      if [[ -n "$alt_profile_dir" ]]; then
        rm -rf "$alt_profile_dir"
      fi
      return 3
    fi

    if [[ -n "$alt_profile_dir" ]]; then
      rm -rf "$alt_profile_dir"
    fi
    return 0
  done

  return 2
}

parse_rows_from_text() {
  local txt_file="$1"
  local out_file="$2"
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
' "$txt_file" > "$out_file"
}

extract_hijri_range() {
  local txt_file="$1"
  grep -E "^[A-Za-z' -]+ [0-9]{4} - [A-Za-z' -]+ [0-9]{4}$" "$txt_file" | head -n 1
}

append_target_rows() {
  local rows_file="$1"
  local range_label="$2"
  local gmonth_abbr="$3"

  month_aliases_for() {
    case "$1" in
      "Muharram") echo "MUHARRAM" ;;
      "Safar") echo "SAFAR" ;;
      "Rabi Al Awwal") echo "RABI AL AWWAL|RABI AL-AWWAL|RABI I|RABI-UL-AWWAL|RABIUL AWWAL|RABI UL AWAL|RABI UL AWWAL|RABI UL-AWAL" ;;
      "Rabi Al Thani") echo "RABI AL THANI|RABI AL-AKHIR|RABI AL-AKHAR|RABI II|RABI-US-SANI|RABIUL AKHIR|RABI AL AKHIR|RABI AL AKHAR|RABI UL AKHIR|RABI UL AKHAR" ;;
      "Jumada Al Ula") echo "JUMADA AL ULA|JUMADA AL-AWWAL|JUMADA I|JUMADA AL OULA|JUMADA-AL-AWWAL|JUMADA-UL-AWWAL" ;;
      "Jumada Al Akhirah") echo "JUMADA AL AKHIRAH|JUMADA AL-AKHIR|JUMADA II|JUMADA AL THANI|JUMADA-UL-AKHIR" ;;
      "Rajab") echo "RAJAB" ;;
      "Shaban") echo "SHABAN|SHA\x27BAN" ;;
      "Ramadan") echo "RAMADAN|RAMAZAN" ;;
      "Shawwal") echo "SHAWWAL" ;;
      "Dhul Qadah") echo "DHUL QADAH|DHUL QA\x27DAH|DHU AL-QIDAH|DHU AL QIDAH|DHUL-QA\x27DAH" ;;
      "Dhul Hijjah") echo "DHUL HIJJAH|DHU AL-HIJJAH|DHU AL HIJJAH|ZUL HIJJAH|DHUL-HIJJAH" ;;
      *) echo "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" ;;
    esac
  }

  local target_aliases
  target_aliases="$(month_aliases_for "$HIJRI_MONTH_NAME")"

  awk \
    -F '\t' \
    -v target_month_aliases="$target_aliases" \
    -v target_year="$YEAR" \
    -v range_label="$range_label" \
    -v gabbr="$gmonth_abbr" \
    '
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  function split_my(label,    p, n, yr) {
    n = split(label, p, /[[:space:]]+/)
    yr = p[n]
    p[n] = ""
    return trim(substr(label, 1, length(label) - length(yr))) "\t" yr
  }
  function norm(s) {
    s = toupper(trim(s))
    gsub(/[-]/, " ", s)
    gsub(/\x27/, "", s)
    gsub(/[[:space:]]+/, " ", s)
    return s
  }
  function month_matches(m, aliases,   mm, a, i, n) {
    mm = norm(m)
    n = split(aliases, a, /[|]/)
    for (i = 1; i <= n; i++) {
      if (mm == norm(a[i])) {
        return 1
      }
    }
    return 0
  }
  BEGIN {
    split(range_label, two, " - ")
    left = split_my(two[1])
    right = split_my(two[2])
    split(left, lparts, "\t")
    split(right, rparts, "\t")
    m1 = trim(lparts[1]); y1 = trim(lparts[2])
    m2 = trim(rparts[1]); y2 = trim(rparts[2])
    seg = 1
    prev_lunar = 0
  }
  {
    day=$1; lunar=$2; solar=$3; fajr=$4; sunrise=$5; zuhr=$6; asr=$7; magrib=$8; isha=$9
    if (prev_lunar > 0 && lunar + 0 < prev_lunar + 0) {
      seg = 2
    }
    prev_lunar = lunar + 0

    cur_month = (seg == 1 ? m1 : m2)
    cur_year = (seg == 1 ? y1 : y2)

    if (month_matches(cur_month, target_month_aliases) && cur_year == target_year) {
      solar_full = solar
      if (gabbr != "") {
        solar_full = solar "-" gabbr
      }
      print day "\t" lunar "\t" solar_full "\t" fajr "\t" sunrise "\t" zuhr "\t" asr "\t" magrib "\t" isha
    }
  }
  ' "$rows_file" >> "$COLLECTED_ROWS"
}

> "$COLLECTED_ROWS"
FETCH_OK=0
FORBIDDEN_403=0

if [[ -n "${CITY_URL:-}" ]]; then
  echo "Fetching prayer data from: $CITY_URL"
  URL="$CITY_URL"
  if ! fetch_month_pdf_text; then
    echo "Error: failed to fetch source PDF from CITY_URL." >&2
    exit 1
  fi
  RANGE_LABEL=$(extract_hijri_range "$RAW_TXT")
  if [[ -z "$RANGE_LABEL" ]]; then
    echo "Error: could not determine Hijri range from CITY_URL response." >&2
    exit 3
  fi
  parse_rows_from_text "$RAW_TXT" "$ROWS_TSV"
  if [[ ! -s "$ROWS_TSV" ]]; then
    echo "Error: could not parse prayer rows from CITY_URL response." >&2
    exit 3
  fi
  append_target_rows "$ROWS_TSV" "$RANGE_LABEL" ""
else
  BASE_GREG_YEAR=$((YEAR + 578))
  # Practical approximation: Muharram tends to fall around June in recent years.
  EST_GREG_MONTH=$((((MONTH_INDEX + 4) % 12) + 1))

  ATTEMPTS=0

  declare -A SCAN_SEEN
  for offset in -3 -2 -1 0 1 2 3; do
    gmonth=$((EST_GREG_MONTH + offset))
    gyear=$BASE_GREG_YEAR
    while (( gmonth < 1 )); do
      gmonth=$((gmonth + 12))
      gyear=$((gyear - 1))
    done
    while (( gmonth > 12 )); do
      gmonth=$((gmonth - 12))
      gyear=$((gyear + 1))
    done

    key="${gyear}-${gmonth}"
    if [[ -n "${SCAN_SEEN[$key]:-}" ]]; then
      continue
    fi
    SCAN_SEEN[$key]=1

    URL_MONTH_INDEX=$((gmonth - 1))
    URL="https://www.islamicfinder.org/prayer-times/printmonthlyprayer/?timeInterval=month&month=${URL_MONTH_INDEX}&year=${gyear}&calendarType=Gregorian"
    echo "Scanning: $URL"

    ATTEMPTS=$((ATTEMPTS + 1))
    fetch_month_pdf_text
    rc=$?
    if (( rc != 0 )); then
      if (( rc == 2 )); then
        FORBIDDEN_403=$((FORBIDDEN_403 + 1))
      fi
      continue
    fi
    FETCH_OK=$((FETCH_OK + 1))

    RANGE_LABEL=$(extract_hijri_range "$RAW_TXT")
    if [[ -z "$RANGE_LABEL" ]]; then
      continue
    fi

    parse_rows_from_text "$RAW_TXT" "$ROWS_TSV"
    if [[ ! -s "$ROWS_TSV" ]]; then
      continue
    fi

    GREG_MONTH_ABBR=$(date -d "$gyear-$(printf '%02d' "$gmonth")-01" '+%b' | tr '[:lower:]' '[:upper:]')
    append_target_rows "$ROWS_TSV" "$RANGE_LABEL" "$GREG_MONTH_ABBR"
  done
fi

if [[ ! -s "$COLLECTED_ROWS" ]]; then
  if (( FORBIDDEN_403 > 0 )); then
    if (( FETCH_OK == 0 )); then
      echo "Error: IslamicFinder blocked all scanned monthly requests with 403 Forbidden." >&2
    else
      echo "Error: IslamicFinder blocked ${FORBIDDEN_403} scanned month(s) with 403 Forbidden; the target Hijri month may be in blocked pages." >&2
    fi
    echo "Try again later, from a different network, or pass CITY_URL for a verified printable monthly page." >&2
    exit 2
  fi
  echo "Error: no rows found for Hijri month '${HIJRI_MONTH_NAME} ${YEAR}'." >&2
  echo "Hint: IslamicFinder does not expose direct Hijri-month print URLs. This script derives Hijri rows from Gregorian monthly data." >&2
  exit 3
fi

# Keep only one continuous Hijri-month run and cap to 30 rows.
awk -F '\t' '
BEGIN { started = 0; prev = -1; count = 0 }
{
  lunar = $2 + 0
  if (!started) {
    if (lunar == 1) {
      started = 1
      prev = 1
      print
      count = 1
    }
    next
  }

  if (lunar == prev + 1 && count < 30) {
    print
    prev = lunar
    count++
    next
  }

  if (count >= 29) {
    exit
  }
}
' "$COLLECTED_ROWS" > "$ROWS_TSV"

if [[ ! -s "$ROWS_TSV" ]]; then
  echo "Error: found candidate rows but could not form a continuous Hijri month sequence." >&2
  exit 3
fi

ROW_COUNT=$(wc -l < "$ROWS_TSV")
if (( ROW_COUNT < 25 )); then
  echo "Error: parsed only $ROW_COUNT rows for ${HIJRI_MONTH_NAME} ${YEAR}; expected 29 or 30." >&2
  exit 4
fi

# Tune table density by month length so the schedule fills one page cleanly.
TABLE_STRETCH="1.5"
TABLE_SIZE_CMD="\\large"
if (( ROW_COUNT <= 29 )); then
  TABLE_STRETCH="1.5"
  TABLE_SIZE_CMD="\\Large"
fi

GREGORIAN_LABEL=""
HIJRI_LABEL="${HIJRI_MONTH_NAME} ${YEAR}"

if [[ -n "$GREGORIAN_LABEL" ]]; then
  GREGORIAN_SUBTITLE_LATEX="{\\normalsize\\textbf{(${GREGORIAN_LABEL})}}\\\\[8pt]"
else
  GREGORIAN_SUBTITLE_LATEX=""
fi

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
${GREGORIAN_SUBTITLE_LATEX}
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
\\textcolor{white}{\\textbf{ISHA}} \\\\ \\hline
EOF

  row_num=0
  while IFS=$'\t' read -r day lunar solar_label fajr sunrise zuhr asr magrib isha; do
    row_num=$((row_num + 1))
    sunset=$(minus_three_minutes "$magrib")
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
