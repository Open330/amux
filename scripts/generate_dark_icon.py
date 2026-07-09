#!/usr/bin/env python3
"""Generate dark mode app icon variants.

The current amux logo is a transparent PNG mark, so the dark appearance
variants use the same raster source as the light icon.

Requires the selected logo source at: design/amux-logo.png
"""
import json
import os
import sys

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LOGO_SOURCE = os.path.join(REPO, "design", "amux-logo.png")

SIZES = [
    ("16.png", 16),
    ("16@2x.png", 32),
    ("32.png", 32),
    ("32@2x.png", 64),
    ("128.png", 128),
    ("128@2x.png", 256),
    ("256.png", 256),
    ("256@2x.png", 512),
    ("512.png", 512),
    ("512@2x.png", 1024),
]


def update_contents_json(icon_dir: str) -> None:
    """Add dark appearance entries to Contents.json."""
    contents_path = os.path.join(icon_dir, "Contents.json")
    with open(contents_path) as f:
        contents = json.load(f)

    # Remove any existing dark entries to avoid duplicates
    images = [
        img for img in contents["images"]
        if not any(
            ap.get("value") == "dark"
            for ap in img.get("appearances", [])
        )
    ]

    dark_images = []
    for img in images:
        filename = img.get("filename", "")
        if not filename:
            continue
        base, ext = os.path.splitext(filename)
        dark_entry = {
            "appearances": [
                {"appearance": "luminosity", "value": "dark"}
            ],
            "filename": f"{base}_dark{ext}",
            "idiom": img["idiom"],
            "scale": img["scale"],
            "size": img["size"],
        }
        dark_images.append(dark_entry)

    # Interleave: light, dark, light, dark, ...
    merged = []
    for i, img in enumerate(images):
        merged.append(img)
        if i < len(dark_images):
            merged.append(dark_images[i])

    contents["images"] = merged
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print(f"  Updated {contents_path}")


def generate_dark_icons(icon_set: str) -> None:
    """Generate dark variants for an icon set."""
    src_dir = os.path.join(REPO, "Assets.xcassets", f"{icon_set}.appiconset")
    if not os.path.isdir(src_dir):
        print(f"SKIP {icon_set} (not found)")
        return

    if not os.path.exists(LOGO_SOURCE):
        print(f"ERROR {LOGO_SOURCE} not found")
        sys.exit(1)

    print(f"\n{icon_set} (using amux logo source):")
    logo = Image.open(LOGO_SOURCE).convert("RGBA")

    for filename, pixel_size in SIZES:
        src_path = os.path.join(src_dir, filename)
        if not os.path.exists(src_path):
            print(f"  SKIP {filename} (not found)")
            continue

        base, ext = os.path.splitext(filename)
        dst_path = os.path.join(src_dir, f"{base}_dark{ext}")

        dark_img = logo.resize((pixel_size, pixel_size), Image.LANCZOS)

        dark_img.save(dst_path, "PNG")
        print(f"  {base}_dark{ext} ({pixel_size}x{pixel_size})")

    update_contents_json(src_dir)


def main():
    generate_dark_icons("AppIcon")


if __name__ == "__main__":
    main()
