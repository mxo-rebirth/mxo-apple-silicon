#!/usr/bin/env python3
"""fps-summary.py <d3d9 log>...

Frame rate in the world, from the DLL's frame log (written when C:\\Games\\dxvk\\debug.flag exists). Each
"FPS" line covers five seconds; only those with more than 2,500 draw calls per frame count as in the world,
which leaves out the login screen, loading and character selection."""
import re
import sys

MIN_DRAWS = 2500

for path in sys.argv[1:]:
    rows = []
    for line in open(path, errors='replace'):
        m = re.match(r'info:\s+FPS (\d+) frames in (\d+) ms.*?per frame: draws (\d+)', line)
        if m and int(m.group(3)) > MIN_DRAWS:
            rows.append(tuple(int(x) for x in m.groups()))
    if not rows:
        print('%s: no five-second window in the world' % path)
        continue
    frames = sum(r[0] for r in rows)
    ms = sum(r[1] for r in rows)
    draws = sum(r[0] * r[2] for r in rows) / frames
    fps = [r[0] * 1000.0 / r[1] for r in rows]
    print('%s: %d windows, %.1f fps on average (%.0f to %.0f), %.0f draw calls per frame, %.2f ms per 1,000 draw calls'
          % (path, len(rows), frames * 1000.0 / ms, min(fps), max(fps), draws, ms / frames / draws * 1000))
