from __future__ import annotations

import json
from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[1]
SVG_PATH = Path(__file__).resolve().parent / "mercury-icon.svg"
APPICON_DIR = ROOT / "Mercury" / "Mercury" / "Assets.xcassets" / "AppIcon.appiconset"
CONTENTS_JSON = APPICON_DIR / "Contents.json"

OUTPUT_NAME = "mercury-appicon"


def parse_size(size_str: str) -> int:
    base = size_str.split("x")[0]
    return int(base)


def scale_factor(scale_str: str) -> int:
    return int(scale_str.replace("x", ""))


def build_filename(base_size: int, scale: int) -> str:
    if scale == 1:
        return f"{OUTPUT_NAME}_{base_size}x{base_size}.png"
    return f"{OUTPUT_NAME}_{base_size}x{base_size}@{scale}x.png"


def main() -> None:
    if not SVG_PATH.exists():
        raise SystemExit(f"SVG not found: {SVG_PATH}")
    if not CONTENTS_JSON.exists():
        raise SystemExit(f"Contents.json not found: {CONTENTS_JSON}")

    APPICON_DIR.mkdir(parents=True, exist_ok=True)

    data = json.loads(CONTENTS_JSON.read_text(encoding="utf-8"))
    images = data.get("images", [])

    for image in images:
        size_str = image.get("size")
        scale_str = image.get("scale")
        idiom = image.get("idiom")
        if idiom != "mac" or not size_str or not scale_str:
            continue

        base_size = parse_size(size_str)
        scale = scale_factor(scale_str)
        px_size = base_size * scale
        filename = build_filename(base_size, scale)
        output_path = APPICON_DIR / filename

        cairosvg.svg2png(url=str(SVG_PATH), write_to=str(output_path), output_width=px_size, output_height=px_size)
        image["filename"] = filename

    CONTENTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("App icon PNGs generated and Contents.json updated.")


if __name__ == "__main__":
    main()
