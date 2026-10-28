"""Writes the empty-state illustrations as SVG, one light and one dark copy.

tools/build_art.sh feeds each SVG to Krita, which saves the editable .kra
and the PNG the app loads. The SVGs are the source of truth; draw in code,
like the app icon, so no third-party art is involved.
"""
import pathlib
import sys

W, H = 360, 240  # drawn at @2x for a 180x120 pt image

PALETTES = {
    "light": dict(blob="#E8EEF8", card="#FFFFFF", stroke="#C9D3E3", line="#D5DDEA",
                  g0="#1C5CED", g1="#21B5DE", spark="#21B5DE"),
    "dark": dict(blob="#26303D", card="#323C4A", stroke="#46546A", line="#4A586E",
                 g0="#3D7BFF", g1="#3CC8EE", spark="#3CC8EE"),
}


def star(x, y, s):
    """A four-point sparkle centred on (x, y)."""
    return (f'<path d="M{x},{y - s} Q{x},{y} {x + s},{y} Q{x},{y} {x},{y + s} '
            f'Q{x},{y} {x - s},{y} Q{x},{y} {x},{y - s} Z" fill="{{spark}}"/>')


def lines(x, y, widths):
    return "".join(f'<rect x="{x}" y="{y + i * 14}" width="{w}" height="6" rx="3" fill="{{line}}"/>'
                   for i, w in enumerate(widths))


COMMON = '<ellipse cx="180" cy="128" rx="132" ry="92" fill="{blob}"/>'

SCENES = {
    # A drive, freshly cleaned.
    "cleaner": COMMON + """
<rect x="105" y="80" width="150" height="92" rx="18" fill="url(#g)"/>
<rect x="125" y="146" width="74" height="8" rx="4" fill="#FFFFFF" fill-opacity="0.5"/>
<circle cx="228" cy="150" r="5" fill="#FFFFFF"/>
<rect x="125" y="100" width="110" height="30" rx="8" fill="#FFFFFF" fill-opacity="0.18"/>
<circle cx="254" cy="80" r="24" fill="{card}" stroke="{stroke}" stroke-width="2"/>
<path d="M243,80 L251,88 L266,72" fill="none" stroke="url(#g)" stroke-width="6"
      stroke-linecap="round" stroke-linejoin="round"/>
""" + star(96, 72, 13) + star(276, 176, 10) + star(128, 196, 7),

    # Documents of different sizes under a magnifier.
    "large-files": COMMON + """
<rect x="112" y="58" width="92" height="120" rx="10" fill="{card}" stroke="{stroke}" stroke-width="2"/>
""" + lines(126, 78, (60, 48, 64)) + """
<rect x="146" y="78" width="104" height="134" rx="10" fill="{card}" stroke="{stroke}" stroke-width="2"/>
<rect x="160" y="94" width="40" height="40" rx="8" fill="url(#g)" fill-opacity="0.9"/>
""" + lines(160, 146, (74, 58, 70)) + """
<circle cx="238" cy="146" r="32" fill="#FFFFFF" fill-opacity="0.25" stroke="url(#g)" stroke-width="10"/>
<path d="M262,170 L288,196" stroke="url(#g)" stroke-width="13" stroke-linecap="round"/>
""" + star(98, 190, 9) + star(272, 70, 12),

    # Two near-identical photos.
    "photos": COMMON + """
<g transform="rotate(-8 170 115)">
  <rect x="105" y="65" width="130" height="100" rx="10" fill="{card}" stroke="{stroke}" stroke-width="2"/>
  <rect x="115" y="75" width="110" height="68" rx="6" fill="{line}"/>
</g>
<g transform="rotate(6 205 137)">
  <rect x="135" y="85" width="140" height="105" rx="10" fill="{card}" stroke="{stroke}" stroke-width="2"/>
  <rect x="145" y="95" width="120" height="75" rx="6" fill="url(#g)"/>
  <path d="M145,170 L183,126 L207,150 L228,131 L265,170 Z" fill="#FFFFFF" fill-opacity="0.85"/>
  <circle cx="240" cy="113" r="9" fill="#FFFFFF" fill-opacity="0.9"/>
</g>
<circle cx="276" cy="84" r="20" fill="url(#g)"/>
<rect x="265" y="77" width="14" height="14" rx="3" fill="none" stroke="#FFFFFF" stroke-width="2.5"/>
<rect x="272" y="72" width="14" height="14" rx="3" fill="url(#g)" stroke="#FFFFFF" stroke-width="2.5"/>
""" + star(92, 84, 11) + star(118, 200, 8),
}


def svg(scene, palette):
    body = SCENES[scene].format(**palette)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="{palette['g0']}"/><stop offset="1" stop-color="{palette['g1']}"/>
</linearGradient></defs>
{body}
</svg>
"""


if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for scene in SCENES:
        for mode, palette in PALETTES.items():
            (out / f"empty-{scene}-{mode}.svg").write_text(svg(scene, palette))
