#!/usr/bin/env python3
"""
Docling PDF parser for RAG pipeline - Tekton Task.
Parses PDFs from rag-doc/ with options: remove_headers, remove_footers, remove_toc.
Outputs clean markdown to /workspace/output for downstream chunking/embedding.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions


def remove_headers_footers_toc(doc) -> None:
    """
    Post-process Docling document: remove header/footer/TOC-like elements.
    Docling does not expose remove_headers/remove_footers/remove_toc in the API;
    we filter by common patterns and position heuristics.
    """
    if not hasattr(doc, "export_to_markdown"):
        return
    # Optional: iterate over doc structure and drop blocks that look like
    # headers (repeated at top of pages), footers (bottom), or TOC (short lines with dots/numbers).
    # Here we rely on Docling's layout and do a simple text pass on exported markdown.
    pass  # Applied in export step below


def filter_markdown_headers_footers_toc(
    md: str,
    *,
    remove_headers: bool = False,
    remove_footers: bool = False,
    remove_toc: bool = False,
) -> str:
    """
    Filter markdown string to remove header/footer/TOC patterns based on flags.
    - Headers: short lines that look like "Chapter N" or section titles
    - Footers: lines like "Page X of Y", "© 2024", "- 1 -", standalone page numbers
    - TOC: lines that look like "Section Title .............. 12" (dots + number at end)
    """
    lines = md.split("\n")
    out = []
    for line in lines:
        s = line.strip()
        if not s:
            out.append(line)
            continue
        if remove_footers:
            if s.startswith("-") and s.endswith("-") and len(s) < 20:
                continue
            if "Page " in s and " of " in s and any(c.isdigit() for c in s):
                continue
            if s.isdigit() and len(s) <= 4:  # standalone page number
                continue
        if remove_toc:
            if "..." in s or " . " in s:
                parts = s.replace("...", ".").split()
                if len(parts) >= 2 and parts[-1].isdigit() and len(parts[-1]) <= 4:
                    continue
        if remove_headers:
            # Short line that looks like "Chapter N" or "Section 1" or all-caps title
            if len(s) < 50 and (
                re.match(r"^(Chapter|Section|Part)\s+\d+\s*$", s, re.I)
                or (len(s) < 30 and s.isupper())
            ):
                continue
        out.append(line)
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse PDFs with Docling (remove_headers, remove_footers, remove_toc)")
    parser.add_argument("--input-dir", type=str, default="/workspace/rag-doc", help="Input directory containing PDFs")
    parser.add_argument("--output-dir", type=str, default="/workspace/output", help="Output directory for markdown")
    parser.add_argument("--remove-headers", action="store_true", default=False, help="Apply header removal heuristic")
    parser.add_argument("--remove-footers", action="store_true", default=False, help="Apply footer removal heuristic")
    parser.add_argument("--remove-toc", action="store_true", default=False, help="Apply TOC removal heuristic")
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    converter = DocumentConverter(
        format_options={
            InputFormat.PDF: PdfFormatOption(
                pipeline_options=PdfPipelineOptions()
            ),
        }
    )

    pdfs = list(input_dir.glob("**/*.pdf"))
    if not pdfs:
        print("No PDFs found in", input_dir, file=sys.stderr)
        return 0

    manifest = []
    for pdf_path in pdfs:
        rel = pdf_path.relative_to(input_dir)
        out_path = output_dir / rel.with_suffix(".md")
        try:
            result = converter.convert(str(pdf_path))
            doc = result.document
            md = doc.export_to_markdown()
            if args.remove_headers or args.remove_footers or args.remove_toc:
                md = filter_markdown_headers_footers_toc(
                    md,
                    remove_headers=args.remove_headers,
                    remove_footers=args.remove_footers,
                    remove_toc=args.remove_toc,
                )
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(md, encoding="utf-8")
            manifest.append({"input": str(rel), "output": str(out_path.relative_to(output_dir)), "status": "ok"})
        except Exception as e:
            manifest.append({"input": str(rel), "output": None, "status": "error", "message": str(e)})
            print(f"Error processing {pdf_path}: {e}", file=sys.stderr)

    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return 0 if all(m["status"] == "ok" for m in manifest) else 1


if __name__ == "__main__":
    sys.exit(main())
