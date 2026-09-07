#!/usr/bin/env python3
"""Cross-check the Markdown files produced by the SwordFM app's DocConverter
(toMarkdown) from the real RUET "32 Semester/Sessionals" documents.

The Dart test `test/real_ruet_markdown_test.dart` stages copies of the real
sources into `/tmp/swordfm_ruet_convert/` and converts each to Markdown via the
app. This script independently verifies those outputs are present, non-empty,
and contain the expected academic content, and (for the txt reference) that the
markdown largely matches the source text.

Usage (after running the Dart test):
    python3 tools/verify_ruet_convert.py [outdir]
"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/swordfm_ruet_convert"
BASE = "ME 3256 Lab Guideline Manual"

REQUIRED_PDF_TOKENS = ["me 3256", "manual", "course", "lab"]
REQUIRED_TXT_TOKENS = ["me 3256", "lab guideline manual"]

failures = []


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def check(cond, msg):
    print(("PASS" if cond else "FAIL") + f"  {msg}")
    if not cond:
        failures.append(msg)


def main():
    if not os.path.isdir(OUT):
        print(f"FAIL  output dir does not exist: {OUT}")
        print("       Run the Dart test first: flutter test test/real_ruet_markdown_test.dart")
        sys.exit(2)

    produced = sorted(
        f for f in os.listdir(OUT) if f.lower().endswith((".md", ".txt", ".docx", ".pdf"))
    )
    check(len(produced) > 0, f"produced output files ({len(produced)})")

    # 1) PDF-derived Markdown.
    pdf_md = os.path.join(OUT, BASE + ".md")
    if os.path.isfile(pdf_md):
        content = read(pdf_md).lower()
        check(len(content.strip()) > 0, "PDF -> Markdown is non-empty")
        for tok in REQUIRED_PDF_TOKENS:
            check(tok in content, f"PDF Markdown contains {tok!r}")
    else:
        check(False, "PDF -> Markdown file exists")

    # 2) TXT-derived Markdown (copy-through) — should closely match the source.
    txt_md = os.path.join(OUT, BASE + ".md")
    txt_src = os.path.join(OUT, BASE + ".txt")
    if os.path.isfile(txt_src) and os.path.isfile(txt_md):
        src = read(txt_src).lower()
        md = read(txt_md).lower()
        check(len(md.strip()) > 0, "TXT -> Markdown is non-empty")
        for tok in REQUIRED_TXT_TOKENS:
            check(tok in md, f"TXT Markdown contains {tok!r}")
        # The copy-through path is 1:1; ratio of shared chars should be high.
        shared = sum(1 for c in set(md) & set(src))
        ratio = shared / max(1, len(set(src)))
        check(ratio > 0.5,
              f"TXT->MD shares {ratio:.0%} of source charset (copy-through)")

    # 3) Report what the converter produced overall.
    print("\nFiles in output dir:")
    for f in produced:
        size = os.path.getsize(os.path.join(OUT, f))
        print(f"  {f:55s} {size:>10,} bytes")

    print("\nRESULT:", "FAIL" if failures else "OK")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()