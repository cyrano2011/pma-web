# 발표자료 빌드

[`../proposal-deck.pdf`](../proposal-deck.pdf) — [제안서 본문](../README.md)을 15장으로 요약한 발표자료(16:9)를 만드는 소스다.
PDF 를 직접 편집하지 말고 여기를 고친 뒤 다시 빌드한다.

## 구성

| 파일 | 역할 |
|---|---|
| `slides.html` | 슬라이드 15장. 다이어그램 자리는 `{{SVG:이름\|폭px}}` 자리표시자 |
| `style.css` | 슬라이드 스타일 (1280×720, 표·카드·노트) |
| `diagrams/*.mmd` | 발표용 mermaid 소스. **문서용 다이어그램과 별개다** — 슬라이드는 더 성기게, 줄바꿈을 손봐서 쓴다 |
| `mermaid.json` | mermaid 테마 (한글 폰트, 폰트 크기) |
| `puppeteer.json` · `render.mjs` | Chromium 렌더링 설정과 PDF 출력 |
| `build.py` | 위를 묶어 `../proposal-deck.pdf` 생성 |

## 빌드

```bash
npm install                 # mermaid-cli + puppeteer
python3 build.py            # → ../proposal-deck.pdf
```

컨테이너처럼 Chromium 이 이미 있는 환경이면 다운로드를 건너뛴다.

```bash
export PUPPETEER_SKIP_BROWSER_DOWNLOAD=1
export PUPPETEER_EXECUTABLE_PATH=/path/to/chromium
export MMDC=./node_modules/.bin/mmdc      # mmdc 가 PATH 에 없을 때
python3 build.py
```

## 알아둘 것

- **한글 폰트가 시스템에 있어야 한다.** 없으면 글자가 전부 두부(□)로 나온다.
  Debian/Ubuntu 계열은 `apt-get install fonts-noto-cjk`. 빌드 후 PDF 에서
  한글 텍스트가 추출되는지 확인하는 것이 가장 빠른 검사다.
- **`build.py` 는 슬라이드 오버플로를 검사한다.** `OVERFLOW: none` 이 아니면
  해당 슬라이드가 720px 를 넘겨 내용이 잘린 것이다. 다이어그램 폭을 줄이거나
  본문을 덜어낸다. 넘친 채로도 PDF 는 생성되므로 이 줄을 반드시 확인할 것.
- **mermaid-cli 는 모든 SVG 에 `id="my-svg"` 를 붙인다.** 한 문서에 여러 개를
  인라인하면 id 가 충돌해 CSS 와 marker(화살촉) 참조가 첫 번째 SVG 로 몰린다.
  `build.py` 가 파일명으로 접두어를 붙여 해결한다.
- **CSS 는 빌드 시 인라인된다.** 결과물이 `build/` 하위로 나가 상대경로 `<link>` 가
  깨지기 때문이다. `build/deck.html` 을 브라우저로 열면 슬라이드를 그대로 볼 수 있다.
