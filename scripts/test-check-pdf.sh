#!/usr/bin/env bash
# Tests for scripts/check-pdf.sh, including cases where the gate must fail.
#
# Usage: scripts/test-check-pdf.sh [pdf] [tex]
#   pdf  a known-good one-page résumé PDF (default: main.pdf)
#   tex  its LaTeX source (default: main.tex)
#
# Requires poppler-utils (pdfinfo, pdftotext).

set -euo pipefail
export LC_ALL=C.UTF-8

here=$(cd "$(dirname "$0")" && pwd)
checker="$here/check-pdf.sh"
pdf=${1:-main.pdf}
tex=${2:-main.tex}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0

# expect <name> <exit code> <text the output must contain, or ""> -- <cmd...>
expect() {
  local name=$1 want_code=$2 want_text=$3
  shift 4
  local out code=0
  out=$("$@" 2>&1) || code=$?
  if [ "$code" -ne "$want_code" ]; then
    echo "FAIL: $name: exit $code, want $want_code"
  elif [ -n "$want_text" ] && ! grep -qF -- "$want_text" <<< "$out"; then
    echo "FAIL: $name: output lacks '$want_text'"
  else
    echo "ok: $name"
    passed=$((passed + 1))
    return
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  failed=$((failed + 1))
}

# make_pdf <out> <content stream> [info dictionary] [pages]
# Writes a PDF (one page by default; every page shows the same content) whose
# Helvetica text maps byte 0x41 ("A") to U+FFFD through its ToUnicode CMap, so
# "A" extracts as a replacement character. Without an info dictionary the PDF
# has no Title or Author metadata.
make_pdf() {
  local out=$1 content=$2 info=${3:-} pages=${4:-1}
  local cmap='/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Test def
1 begincodespacerange
<00> <FF>
endcodespacerange
1 beginbfchar
<41> <FFFD>
endbfchar
endcmap
CMapName currentdict /CMap defineresource pop
end
end'
  local page='<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>'
  # Page 1 is object 3; further pages follow the fixed objects, from 7 on.
  local kids='3 0 R' n
  for ((n = 7; n < pages + 6; n++)); do
    kids+=" $n 0 R"
  done
  local objs=(
    '<< /Type /Catalog /Pages 2 0 R >>'
    "<< /Type /Pages /Kids [$kids] /Count $pages >>"
    "$page"
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R >>'
    "<< /Length ${#content} >>
stream
$content
endstream"
    "<< /Length ${#cmap} >>
stream
$cmap
endstream"
  )
  for ((n = 1; n < pages; n++)); do
    objs+=("$page")
  done
  local trailer_info=""
  if [ -n "$info" ]; then
    objs+=("$info")
    trailer_info=" /Info ${#objs[@]} 0 R"
  fi
  local body offsets=() i
  body=$'%PDF-1.4\n'
  for i in "${!objs[@]}"; do
    offsets+=("${#body}")
    body+="$((i + 1)) 0 obj
${objs[$i]}
endobj
"
  done
  local xref=${#body}
  body+="xref"$'\n'"0 $((${#objs[@]} + 1))"$'\n'
  body+=$'0000000000 65535 f \n'
  for i in "${offsets[@]}"; do
    body+=$(printf '%010d 00000 n ' "$i")$'\n'
  done
  body+="trailer
<< /Size $((${#objs[@]} + 1)) /Root 1 0 R$trailer_info >>
startxref
$xref
%%EOF
"
  printf '%s' "$body" > "$out"
}

metadata='<< /Title (Test) /Author (Test) >>'
make_pdf "$tmp/two-pages.pdf" 'BT /F1 24 Tf 72 700 Td (Test Education) Tj ET' "$metadata" 2
make_pdf "$tmp/replacement-char.pdf" 'BT /F1 24 Tf 72 700 Td (Test Education A) Tj ET' "$metadata"
make_pdf "$tmp/no-text.pdf" '' "$metadata"
make_pdf "$tmp/no-metadata.pdf" 'BT /F1 24 Tf 72 700 Td (Test Education) Tj ET'
make_pdf "$tmp/empty-title.pdf" 'BT /F1 24 Tf 72 700 Td (Test Education) Tj ET' '<< /Title ( ) /Author (Test) >>'
make_pdf "$tmp/author-not-on-page.pdf" 'BT /F1 24 Tf 72 700 Td (Test Education) Tj ET' '<< /Title (Test) /Author (Someone Else) >>'

printf '\\section{Education}\n' > "$tmp/education.tex"
printf '\\documentclass{article}\n\\begin{document}\nNo sections.\n\\end{document}\n' > "$tmp/no-sections.tex"
{ cat "$tex"; printf '\\section{Heading That Is Not In The PDF}\n'; } > "$tmp/extra-heading.tex"
{ cat "$tex"; printf '%% \\section{Commented Out Heading}\n'; } > "$tmp/commented-heading.tex"

expect "good PDF passes" 0 "1 page(s) (budget 1)" -- \
  "$checker" "$pdf" "$tex"
expect "two pages exceed the default budget" 1 "has 2 pages; the page budget allows 1" -- \
  "$checker" "$tmp/two-pages.pdf" "$tmp/education.tex"
expect "MAX_PAGES=2 allows two pages" 0 "2 page(s) (budget 2)" -- \
  env MAX_PAGES=2 "$checker" "$tmp/two-pages.pdf" "$tmp/education.tex"
expect "invalid MAX_PAGES is rejected" 2 "MAX_PAGES must be a positive integer" -- \
  env MAX_PAGES=0 "$checker" "$pdf" "$tex"
expect "missing section heading fails" 1 "section heading 'Heading That Is Not In The PDF'" -- \
  "$checker" "$pdf" "$tmp/extra-heading.tex"
expect "commented-out heading is ignored" 0 "" -- \
  "$checker" "$pdf" "$tmp/commented-heading.tex"
expect "U+FFFD in extracted text fails" 1 "contains 1 U+FFFD replacement character(s)" -- \
  "$checker" "$tmp/replacement-char.pdf" "$tmp/education.tex"
expect "U+FFFD is the synthetic PDF's only problem" 1 "PDF check failed: 1 problem(s)" -- \
  "$checker" "$tmp/replacement-char.pdf" "$tmp/education.tex"
expect "PDF without text fails" 1 "pdftotext extracted no text" -- \
  "$checker" "$tmp/no-text.pdf" "$tmp/education.tex"
expect "PDF without a Title fails" 1 "has no Title in its metadata" -- \
  "$checker" "$tmp/no-metadata.pdf" "$tmp/education.tex"
expect "PDF without an Author fails" 1 "has no Author in its metadata" -- \
  "$checker" "$tmp/no-metadata.pdf" "$tmp/education.tex"
expect "missing Title and Author are the synthetic PDF's only problems" 1 "PDF check failed: 2 problem(s)" -- \
  "$checker" "$tmp/no-metadata.pdf" "$tmp/education.tex"
expect "blank Title fails on its own" 1 "has no Title in its metadata" -- \
  "$checker" "$tmp/empty-title.pdf" "$tmp/education.tex"
expect "blank Title is the synthetic PDF's only problem" 1 "PDF check failed: 1 problem(s)" -- \
  "$checker" "$tmp/empty-title.pdf" "$tmp/education.tex"
expect "Author missing from the page fails" 1 "PDF author 'Someone Else' does not appear" -- \
  "$checker" "$tmp/author-not-on-page.pdf" "$tmp/education.tex"
expect "source without headings fails" 1 "found no \\section headings" -- \
  "$checker" "$pdf" "$tmp/no-sections.tex"
expect "missing PDF is a usage error" 2 "cannot read" -- \
  "$checker" "$tmp/does-not-exist.pdf" "$tex"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
