#!/usr/bin/env python3
"""swordconv — document conversion engine for SwordFM Android (Termux).

Runs under Termux's python (/data/data/com.termux/files/usr/bin/python).

Usage: swordconv <target-format> <input-file> <output-file>
Formats: pdf, docx, md, txt, html

This is a trimmed port of the SwordFM Linux `tools/swordconv`, adapted for
Android's Termux. Deliberately NO LibreOffice/pandoc (huge, slow to start) and
NO pdf2docx/opencv (not reliably buildable on Termux, and it only wrapped PDF
pages as images anyway).

Conversion model: read any source into (plain-text, html) via a reader, then
write the target from that shared representation with a writer. This yields
*real* editable re-layout output (python-docx, PyMuPDF Story). Images embedded
in a source PDF are NOT copied into the DOCX — that is an honest tradeoff: the
only way to do that on Android is heavy native libs.

Exits non-zero with a plain-English message on stderr; the Dart bridge shows
that text verbatim in a dialog.
"""

import html as htmlmod
import os
import re
import sys


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def need(mod, hint):
    try:
        return __import__(mod)
    except ImportError:
        die("Missing Python module '%s'.\nInstall it with:  %s" % (mod, hint))


# --------------------------------------------------------------------------
# readers: anything -> (plain_text, html)
# --------------------------------------------------------------------------

def read_pdf(path):
    fitz = need("fitz", "pip install pymupdf")
    doc = fitz.open(path)
    if doc.needs_pass:
        die("That PDF is password protected.")

    # TEXT_DEHYPHENATE also expands ligatures, otherwise "first" comes back as
    # the single glyph "first" and every downstream search for it fails.
    flags = fitz.TEXT_DEHYPHENATE

    # A PDF has no headings, only text at different sizes. Collect every line
    # with its size so larger-than-body lines can be promoted back to headings;
    # without this a converted document is one flat wall of paragraphs.
    lines = []
    sizes = []
    for page in doc:
        for block in page.get_text("dict", flags=flags).get("blocks", []):
            for line in block.get("lines", []):
                text = "".join(s.get("text", "") for s in line.get("spans", []))
                if not text.strip():
                    continue
                size = max((s.get("size", 0) for s in line.get("spans", [])),
                           default=0)
                spans = [s for s in line.get("spans", []) if s.get("text", "").strip()]
                # Whole line bold, not merely containing a bold word — otherwise
                # any paragraph with an emphasised phrase becomes a heading.
                bold = bool(spans) and all(s.get("flags", 0) & 16 for s in spans)
                lines.append((text.rstrip(), round(size, 1), bold))
                sizes.append(round(size, 1))

    if not lines:
        die("No text found in that PDF — it is probably a scan.\n"
            "Run it through OCR first (e.g. ocrmypdf) and try again.")

    body_size = max(set(sizes), key=sizes.count)  # most common size == body text

    html_parts = []
    para = []

    def flush():
        if para:
            html_parts.append("<p>%s</p>" % htmlmod.escape(" ".join(para)))
            para.clear()

    for text, size, bold in lines:
        stripped = text.strip()
        if re.match(r"^[•\-*]\s+", stripped):
            flush()
            html_parts.append("<ul><li>%s</li></ul>" %
                              htmlmod.escape(re.sub(r"^[•\-*]\s+", "",
                                                    stripped)))
        elif size > body_size * 1.15 or (bold and size >= body_size
                                         and len(stripped) < 80):
            flush()
            level = (1 if size > body_size * 1.5
                     else (2 if size > body_size * 1.25 else 3))
            html_parts.append("<h%d>%s</h%d>" %
                              (level, htmlmod.escape(stripped), level))
        else:
            para.append(stripped)
    flush()

    text = "\n".join(l[0] for l in lines)
    return text, "\n".join(html_parts)


def read_docx(path):
    mammoth = need("mammoth", "pip install mammoth")
    with open(path, "rb") as f:
        html = mammoth.convert_to_html(f).value
    docx = need("docx", "pip install python-docx")
    text = "\n\n".join(p.text for p in docx.Document(path).paragraphs
                       if p.text.strip())
    return text, html


def read_md(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    return text, md_to_html(text)


def read_txt(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    body = "".join("<p>%s</p>" % htmlmod.escape(p).replace("\n", "<br/>")
                   for p in re.split(r"\n\s*\n", text) if p.strip())
    return text, body


def read_html(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        html = f.read()
    return html_to_text(html), html


# --------------------------------------------------------------------------
# markdown / html
# --------------------------------------------------------------------------

def md_to_html(text):
    """Markdown -> HTML (markdown pkg when present, tiny fallback otherwise)."""
    try:
        import markdown
        return markdown.markdown(text, extensions=["fenced_code", "tables"])
    except ImportError:
        pass

    out = []
    in_list = False
    in_code = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            out.append("</pre>" if in_code else "<pre>")
            in_code = not in_code
            continue
        if in_code:
            out.append(htmlmod.escape(line))
            continue
        esc = htmlmod.escape(line)
        esc = re.sub(r"`([^`]+)`", r"<code>\1</code>", esc)
        esc = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", esc)
        esc = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", esc)
        esc = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', esc)
        m = re.match(r"^(#{1,6})\s+(.*)$", esc)
        if m:
            if in_list:
                out.append("</ul>")
                in_list = False
            lvl = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (lvl, m.group(2), lvl))
            continue
        m = re.match(r"^\s*[-*+]\s+(.*)$", esc)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % m.group(1))
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if esc.strip():
            out.append("<p>%s</p>" % esc)
    if in_list:
        out.append("</ul>")
    if in_code:
        out.append("</pre>")
    return "\n".join(out)


def html_to_text(html):
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        BeautifulSoup = None
    if BeautifulSoup is not None:
        soup = BeautifulSoup(html, "html.parser")
        for tag in soup(["script", "style"]):
            tag.decompose()
        return re.sub(r"\n{3,}", "\n\n", soup.get_text("\n")).strip()
    stripped = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", html,
                      flags=re.S | re.I)
    stripped = re.sub(r"<br\s*/?>|</p>|</div>|</h[1-6]>", "\n", stripped,
                      flags=re.I)
    return re.sub(r"\n{3,}", "\n\n",
                  htmlmod.unescape(re.sub(r"<[^>]+>", "", stripped))).strip()


# --------------------------------------------------------------------------
# writers
# --------------------------------------------------------------------------

def write_pdf(html, out):
    fitz = need("fitz", "pip install pymupdf")
    story = fitz.Story(html="<html><body>%s</body></html>" % html)
    writer = fitz.DocumentWriter(out)
    mediabox = fitz.paper_rect("a4")
    area = mediabox + (54, 54, -54, -54)
    more = 1
    guard = 0
    while more:
        dev = writer.begin_page(mediabox)
        more, _ = story.place(area)
        story.draw(dev)
        writer.end_page()
        guard += 1
        if guard > 5000:
            die("Document is too large to lay out.")
    writer.close()


def write_docx(html, out):
    docx = need("docx", "pip install python-docx")
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        die("Missing Python module 'bs4'.\nInstall it with:  pip install beautifulsoup4")
    doc = docx.Document()
    soup = BeautifulSoup(html, "html.parser")

    def add_runs(par, node):
        for child in node.children:
            if child.name is None:
                t = str(child.string or "")
                if t:
                    par.add_run(t)
            elif child.name in ("b", "strong"):
                par.add_run(child.get_text()).bold = True
            elif child.name in ("i", "em"):
                par.add_run(child.get_text()).italic = True
            elif child.name == "code":
                r = par.add_run(child.get_text())
                r.font.name = "Monospace"
            elif child.name == "br":
                par.add_run("\n")
            else:
                add_runs(par, child)

    body = soup.body or soup
    for el in body.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li",
                             "pre"], recursive=True):
        text = el.get_text().strip()
        if not text:
            continue
        if re.fullmatch(r"h[1-6]", el.name):
            doc.add_heading(text, min(int(el.name[1]), 9))
        elif el.name == "li":
            doc.add_paragraph(text, style="List Bullet")
        elif el.name == "pre":
            p = doc.add_paragraph()
            p.add_run(text).font.name = "Monospace"
        else:
            add_runs(doc.add_paragraph(), el)

    if not doc.paragraphs:
        doc.add_paragraph(html_to_text(html))
    doc.save(out)


def write_text(text, out):
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)


# --------------------------------------------------------------------------

READERS = {
    ".pdf": read_pdf, ".docx": read_docx, ".md": read_md, ".markdown": read_md,
    ".txt": read_txt, ".text": read_txt, ".html": read_html, ".htm": read_html,
}

# Canonical list of output formats the Dart bridge offers.
TARGETS = {"pdf", "docx", "md", "markdown", "txt", "text", "html"}


def main():
    if len(sys.argv) != 4:
        die("usage: swordconv <pdf|docx|md|txt|html> <input> <output>")
    target, src, out = (sys.argv[1].lower().lstrip("."),
                        sys.argv[2], sys.argv[3])

    if target not in TARGETS:
        die("Unknown target format: %s" % sys.argv[1])
    if not os.path.isfile(src):
        die("No such file: %s" % src)

    ext = os.path.splitext(src)[1].lower()
    reader = READERS.get(ext)
    if reader is None:
        die("Cannot read %s files.\nSupported: PDF, DOCX, Markdown, TXT, HTML"
            % (ext or "these"))

    # PDF -> DOCX: old swordconv routed to pdf2docx (wraps pages as images,
    # needs opencv/numpy). On Termux that is unreliable, and the output is not
    # an editable DOCX anyway. Here we route PDF through the same text re-layout
    # reader+writer as everyone else — a genuine, editable Word document.
    text, html = reader(src)

    if target == "pdf":
        write_pdf(html, out)
    elif target == "docx":
        write_docx(html, out)
    elif target in ("md", "markdown"):
        from_html_to_md = (ext in (".pdf", ".docx", ".html", ".htm"))
        write_text(html_to_md(html) if from_html_to_md else text, out)
    elif target in ("txt", "text"):
        write_text(text, out)
    elif target == "html":
        write_text("<!DOCTYPE html>\n<html><meta charset=\"utf-8\">\n"
                   "<body>\n%s\n</body></html>\n" % html, out)

    if not os.path.exists(out):
        die("Conversion produced no output.")


def html_to_md(html):
    """HTML -> Markdown, for the pdf/docx -> md direction."""
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        return html_to_text(html)
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style"]):
        tag.decompose()

    def walk(node):
        if node.name is None:
            return node.string or ""
        inner = "".join(walk(c) for c in node.children)
        n = node.name
        if re.fullmatch(r"h[1-6]", n or ""):
            return "\n\n%s %s\n\n" % ("#" * int(n[1]), inner.strip())
        if n in ("b", "strong"):
            return "**%s**" % inner.strip() if inner.strip() else ""
        if n in ("i", "em"):
            return "*%s*" % inner.strip() if inner.strip() else ""
        if n == "code":
            return "`%s`" % inner.strip()
        if n == "pre":
            return "\n\n```\n%s\n```\n\n" % inner.strip("\n")
        if n == "li":
            return "- %s\n" % inner.strip()
        if n in ("ul", "ol"):
            return "\n" + inner + "\n"
        if n == "a":
            href = node.get("href", "")
            return "[%s](%s)" % (inner.strip(), href) if href else inner
        if n == "br":
            return "\n"
        if n in ("p", "div"):
            return "\n\n%s\n\n" % inner.strip()
        return inner

    return re.sub(r"\n{3,}", "\n\n", walk(soup)).strip() + "\n"


if __name__ == "__main__":
    main()