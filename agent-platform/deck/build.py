#!/usr/bin/env python3
"""slides.html + diagrams/*.mmd → deck.pdf

  1) mermaid-cli 로 각 .mmd 를 SVG 로 렌더
  2) slides.html 의 {{SVG:이름|폭}} 자리에 SVG 를 인라인
     (mermaid-cli 는 모든 SVG 에 id="my-svg" 를 붙인다. 한 문서에 여러 개를
      인라인하면 id 충돌로 CSS·marker 참조가 첫 SVG 로 몰리므로 접두어를 붙인다)
  3) Chromium 으로 1280x720 PDF 출력, 슬라이드 오버플로 검사
"""
import os, re, subprocess, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "build"
OUT.mkdir(exist_ok=True)

MMDC = os.environ.get("MMDC", "mmdc")  # @mermaid-js/mermaid-cli

def render_diagrams():
    for mmd in sorted((HERE / "diagrams").glob("*.mmd")):
        svg = OUT / f"{mmd.stem}.svg"
        subprocess.run(
            [MMDC, "-p", str(HERE / "puppeteer.json"),
             "-c", str(HERE / "mermaid.json"), "-b", "transparent",
             "-i", str(mmd), "-o", str(svg)],
            check=True, capture_output=True)
        print("svg  ", svg.name)

def inline():
    html = (HERE / "slides.html").read_text()
    # build/ 하위로 나가므로 상대경로 <link> 가 깨진다. CSS 를 인라인해 자체완결시킨다.
    html = html.replace(
        '<link rel="stylesheet" href="style.css">',
        "<style>\n" + (HERE / "style.css").read_text() + "\n</style>")
    def sub(m):
        name, width = m.group(1), m.group(2)
        svg = (OUT / f"{name}.svg").read_text().replace("my-svg", f"mm-{name}")
        svg = re.sub(r'\s(?:width|height)="[^"]*"', ' ', svg, count=1)
        svg = svg.replace("<svg ", '<svg width="100%" ', 1)
        return f'<div style="width:{width}px;max-width:100%">{svg}</div>'
    html, n = re.subn(r"\{\{SVG:([a-z0-9_]+)\|(\d+)\}\}", sub, html)
    if "{{SVG" in html:
        sys.exit("치환되지 않은 SVG 자리표시자가 남았다")
    (OUT / "deck.html").write_text(html)
    print(f"inlined {n} diagrams")

def to_pdf():
    subprocess.run(["node", str(HERE / "render.mjs"),
                    str(OUT / "deck.html"), str(HERE.parent / "proposal-deck.pdf")], check=True)

if __name__ == "__main__":
    render_diagrams(); inline(); to_pdf()
