#!/usr/bin/env bash
# Quality gate for the compiled résumé PDF.
#
# Usage: scripts/check-pdf.sh <pdf> <tex>
#
# Fails (exit 1) when:
#   - the PDF has more pages than MAX_PAGES (default 1);
#   - pdftotext extracts no text, or text containing U+FFFD replacement
#     characters;
#   - any \section{...} heading from the .tex source is missing from the
#     extracted text (compared case-insensitively, whitespace collapsed).
# Exit 2 means the checker could not run (bad arguments or missing tools).
#
# Each failure is printed as a GitHub Actions ::error:: annotation.
# Requires poppler-utils (pdfinfo, pdftotext) and perl.

set -euo pipefail

# Make grep and ${#var} UTF-8 aware so Turkish characters count and match
# correctly.
export LC_ALL=C.UTF-8

usage() {
  echo "usage: $0 <pdf> <tex>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
pdf=$1
tex=$2
max_pages=${MAX_PAGES:-1}

for tool in pdfinfo pdftotext perl; do
  if ! command -v "$tool" > /dev/null; then
    echo "::error::$tool is not installed (install poppler-utils)"
    exit 2
  fi
done

if ! [[ "$max_pages" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::MAX_PAGES must be a positive integer, got '$max_pages'"
  exit 2
fi
for f in "$pdf" "$tex"; do
  if [ ! -r "$f" ]; then
    echo "::error::cannot read $f"
    exit 2
  fi
done

failures=0
fail() {
  echo "::error file=$1::$2"
  failures=$((failures + 1))
}

# --- Page budget -----------------------------------------------------------
if ! info=$(pdfinfo "$pdf" 2>&1); then
  echo "::error file=$pdf::pdfinfo could not read $pdf: $info"
  exit 1
fi
pages=$(printf '%s\n' "$info" | sed -n 's/^Pages:[[:space:]]*//p')
if ! [[ "$pages" =~ ^[0-9]+$ ]]; then
  echo "::error file=$pdf::pdfinfo did not report a page count for $pdf"
  exit 1
fi
if [ "$pages" -gt "$max_pages" ]; then
  fail "$tex" "$pdf has $pages pages; the page budget allows $max_pages (set MAX_PAGES to change it)"
fi

# --- Text extraction -------------------------------------------------------
if ! text=$(pdftotext -enc UTF-8 "$pdf" - 2>&1); then
  echo "::error file=$pdf::pdftotext could not extract text from $pdf: $text"
  exit 1
fi

if [[ ! "$text" =~ [^[:space:]] ]]; then
  fail "$tex" "pdftotext extracted no text from $pdf"
fi

replacements=$(printf '%s' "$text" | grep -o $'\xef\xbf\xbd' | wc -l || true)
if [ "$replacements" -gt 0 ]; then
  fail "$tex" "text extracted from $pdf contains $replacements U+FFFD replacement character(s); some glyphs have no Unicode mapping"
fi

# Collapse whitespace (headings may wrap) and expand common ligatures.
flat=$(printf '%s' "$text" | sed 's/ﬁ/fi/g; s/ﬂ/fl/g; s/ﬀ/ff/g' | tr -s '[:space:]' ' ')

# Print each \section{...} / \section*{...} heading of the source, one per
# line, as it should read in the PDF: comments dropped, common LaTeX escapes
# and dashes turned into text, other commands and braces removed.
read_headings() {
  perl -0777 -CSD -ne '
    s/(?<!\\)%[^\n]*//g;
    while (/\\section\*?\s*(?:\[[^\]]*\])?\s*(\{(?:[^{}]++|(?1))*\})/g) {
      my $h = substr($1, 1, -1);
      $h =~ s/\\([&%\$#_{}])/$1/g;
      $h =~ s/---/\x{2014}/g;
      $h =~ s/--/\x{2013}/g;
      $h =~ s/~/ /g;
      $h =~ s/\\[a-zA-Z]+\*?//g;
      $h =~ s/[{}]//g;
      $h =~ s/\s+/ /g;
      $h =~ s/^ | $//g;
      print "$h\n" if length $h;
    }
  ' "$1"
}

headings=()
while IFS= read -r heading; do
  headings+=("$heading")
done < <(read_headings "$tex")

if [ "${#headings[@]}" -eq 0 ]; then
  fail "$tex" "found no \\section headings in $tex to look for in the PDF"
fi
for heading in "${headings[@]}"; do
  if ! grep -qiF -- "$heading" <<< "$flat"; then
    fail "$tex" "section heading '$heading' from $tex is missing from the text extracted from $pdf"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "PDF check failed: $failures problem(s) in $pdf" >&2
  exit 1
fi

echo "PDF check passed: $pdf has $pages page(s) (budget $max_pages), ${#text} characters extracted, all ${#headings[@]} section headings found"
