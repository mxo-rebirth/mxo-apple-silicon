#!/usr/bin/env python3
"""fps-summary.py <d3d9 log>...

Frame rate in the world, from the DLL's frame log (written when C:\\Games\\dxvk\\debug.flag exists). Each
"FPS" line covers five seconds. Only those with more than 2,500 draw calls per frame count as in the world,
which leaves out the login screen, loading and character selection."""
import re
import sys

MIN_DRAWS = 2500
FPS_LINE = re.compile(r'info:\s+FPS (\d+) frames in (\d+) ms.*?per frame: draws (\d+)')


def summary(path):
    """One line about a log: how many five-second windows lie in the world, and their frame rate and draw calls."""
    windows = []                # (frames, milliseconds, draw calls per frame)
    with open(path, errors='replace') as file:
        for line in file:
            found = FPS_LINE.match(line)
            if found:
                frames, milliseconds, draws = [int(number) for number in found.groups()]
                if draws > MIN_DRAWS and frames and milliseconds:
                    windows.append((frames, milliseconds, draws))
    if not windows:
        return '%s: no five-second window in the world' % path
    frames = sum(window[0] for window in windows)
    milliseconds = sum(window[1] for window in windows)
    draws = sum(window[0] * window[2] for window in windows) / frames
    rates = [window[0] * 1000.0 / window[1] for window in windows]
    return ('%s: %d windows, %.1f fps on average (%.0f to %.0f), %.0f draw calls per frame, %.2f ms per 1,000 draw calls'
            % (path, len(windows), frames * 1000.0 / milliseconds, min(rates), max(rates), draws,
               milliseconds / frames / draws * 1000))


def main(paths):
    if not paths:
        raise SystemExit(__doc__)
    for path in paths:
        try:
            print(summary(path))
        except OSError as failure:
            raise SystemExit('fps-summary.py: %s' % failure) from failure


if __name__ == '__main__':
    main(sys.argv[1:])
