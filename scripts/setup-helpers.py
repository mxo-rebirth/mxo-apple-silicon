#!/usr/bin/env python3
"""setup-helpers.py

The file edits and page readings of scripts/setup.sh, one subcommand each:

    page-link PAGE BASE PATTERN         the installer a download page offers, as "URL SHA256"
    dotnet-link RELEASES                the newest .NET Desktop Runtime installer for Windows x64, as "URL SHA512"
    get-env CONF NAME                   a variable in a bottle's cxbottle.conf, nothing when it is not set
    set-env CONF NAME=VALUE...          sets variables in the section [EnvironmentVariables]
    unset-env CONF NAME...              removes them from that section
    get-option FILE KEY                 the value of a "KEY = VALUE" line in a settings file of the game
    set-options FILE LINES              sets "KEY = VALUE" lines and adds the missing ones
    set-options --existing FILE LINES   sets them only where the key is there already
    video-off SETTINGS                  "BackgroundVideo": false in Revived's launcher-settings.json

PAGE and RELEASES are files, or "-" for standard input.

A file is changed by writing a new one next to it and renaming that, so a failure leaves the old file
whole. A key is found at the start of a line, after any blanks, before "=". The game reads its keys in
any case, so they are matched in any case. Names of environment variables are matched exactly. Where a
key is there more than once, every line gets the new value and the last one is read.

Standard library only. Started with python3 -I."""

import html
import json
import os
import re
import shutil
import sys
from urllib.parse import urljoin

BYTE_ORDER_MARK = b'\xef\xbb\xbf'
ENV_SECTION = '[EnvironmentVariables]'


def read_bytes(path):
    if path == '-':
        return sys.stdin.buffer.read()
    with open(path, 'rb') as file:
        return file.read()


def write_whole(path, data):
    """Writes DATA to a new file next to PATH and renames it over PATH."""
    new = path + '.new'
    try:
        with open(new, 'wb') as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        if os.path.exists(path):
            shutil.copymode(path, new)
        os.replace(new, path)
    finally:
        if os.path.exists(new):
            os.unlink(new)


def key_line(key, any_case):
    """Matches a line that sets KEY: the one rule for finding a key."""
    return re.compile(r'[ \t]*%s[ \t]*=' % re.escape(key), re.I if any_case else 0)


def split_lines(text):
    """TEXT as lines that keep their own carriage return, and the carriage return a new line gets."""
    return text.split('\n'), '\r' if '\r\n' in text else ''


def value_of(line):
    """What a "KEY = VALUE" line has after its "=", without the quotes cxbottle.conf puts around it."""
    value = line.split('=', 1)[1].strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


# --- the game's settings files: options.cfg, useropts.cfg, dxvk.conf, Revived's music guard ---

def read_settings(path):
    """The lines of a settings file without the empty ones at its end, the carriage return for new
    lines and the file's byte order mark. A file that is not there has no lines."""
    raw = read_bytes(path) if os.path.exists(path) else b''
    mark = BYTE_ORDER_MARK if raw.startswith(BYTE_ORDER_MARK) else b''
    text = raw[len(mark):].decode('latin-1')   # every byte stays what it is
    lines, carriage = split_lines(text)
    if text and not text.endswith('\n'):
        lines[-1] += carriage
    while lines and lines[-1].strip() == '':
        lines.pop()
    return lines, carriage if text else '\r', mark


def get_option(path, key):
    lines, _carriage, _mark = read_settings(path)
    pattern = key_line(key, any_case=True)
    values = [value_of(line) for line in lines if pattern.match(line)]
    if values:
        print(values[-1])


def set_options(*arguments):
    existing_only = arguments[:1] == ('--existing',)
    if len(arguments) != (3 if existing_only else 2):
        raise ValueError('takes [--existing] FILE LINES')
    path, wanted = arguments[1:] if existing_only else arguments
    lines, carriage, mark = read_settings(path)
    before = list(lines)
    for item in wanted.split('\n'):
        if '=' not in item:
            continue
        key, value = [part.strip() for part in item.split('=', 1)]
        pattern = key_line(key, any_case=True)
        found = False
        for number, line in enumerate(lines):
            if pattern.match(line):   # the key keeps the spelling the file has
                lines[number] = '%s = %s%s' % (line.split('=', 1)[0].strip(), value, '\r' if line.endswith('\r') else '')
                found = True
        if not found and not existing_only:
            lines.append('%s = %s%s' % (key, value, carriage))
    if lines != before:
        write_whole(path, mark + ('\n'.join(lines) + '\n').encode('latin-1'))


# --- a bottle's cxbottle.conf ---

def read_conf(path):
    return split_lines(read_bytes(path).decode('utf-8', 'surrogateescape'))


def write_conf(path, lines):
    if lines[-1] != '':
        lines.append('')
    write_whole(path, '\n'.join(lines).encode('utf-8', 'surrogateescape'))


def env_section(lines):
    """The numbers of the section's header line and of the line after its last one, or None."""
    start = None
    for number, line in enumerate(lines):
        if start is None:
            if line.strip() == ENV_SECTION:
                start = number
        elif line.lstrip().startswith('['):
            return start, number
    return None if start is None else (start, len(lines))


def env_lines(lines, name):
    """The numbers of the lines in the section that set NAME."""
    section = env_section(lines)
    if section is None:
        return []
    pattern = key_line('"%s"' % name, any_case=False)
    return [number for number in range(section[0] + 1, section[1]) if pattern.match(lines[number])]


def get_env(path, name):
    lines, _carriage = read_conf(path)
    found = env_lines(lines, name)
    if found:
        print(value_of(lines[found[-1]]))


def set_env(path, *pairs):
    lines, carriage = read_conf(path)
    before = list(lines)
    for pair in pairs:
        if '=' not in pair:
            raise ValueError('not NAME=VALUE: %s' % pair)
        name, value = pair.split('=', 1)
        new = '"%s" = "%s"' % (name, value)
        found = env_lines(lines, name)
        for number in found:
            lines[number] = new + ('\r' if lines[number].endswith('\r') else '')
        if found:
            continue
        section = env_section(lines)
        if section is None:   # a new section at the end, after an empty line
            while lines and lines[-1].strip() == '':
                lines.pop()
            lines += ([carriage] if lines else []) + [ENV_SECTION + carriage, new + carriage, '']
        else:
            lines.insert(section[0] + 1, new + carriage)
    if lines != before:
        write_conf(path, lines)


def unset_env(path, *names):
    lines, _carriage = read_conf(path)
    dropped = {number for name in names for number in env_lines(lines, name)}
    if dropped:
        write_conf(path, [line for number, line in enumerate(lines) if number not in dropped])


# --- Revived's launcher ---

def video_off(path):
    raw = read_bytes(path)
    mark = BYTE_ORDER_MARK if raw.startswith(BYTE_ORDER_MARK) else b''
    text = raw[len(mark):].decode('utf-8')
    new, count = re.subn(r'("BackgroundVideo"\s*:\s*)true', r'\1false', text)
    if count == 0 and '"BackgroundVideo"' not in text:
        settings = json.loads(text)
        if not isinstance(settings, dict):
            raise ValueError('the settings are not a JSON object')
        settings['BackgroundVideo'] = False
        new = json.dumps(settings, indent=2).replace('\n', '\r\n')
    if new != text:
        write_whole(path, mark + new.encode('utf-8'))


# --- the publishers' pages ---

def page_link(page_path, base, pattern):
    """Prints the link to the file a page offers and the SHA-256 the page prints after the file's
    name. Returns 1 when the page has no such link, no checksum for it, or a link that is not https."""
    page = read_bytes(page_path).decode('utf-8', 'replace')
    link = re.search(r'href="([^"]*/)?(%s)"' % pattern, page)
    if not link:
        return 1
    name = link.group(2)
    url = urljoin(base, (link.group(1) or '') + name)
    # the checksum that comes after the file's name, before the page names another file
    text = html.unescape(re.sub(r'<[^>]*>', ' ', re.sub(r'(?s)<(script|style)\b.*?</\1>', ' ', page)))
    found = re.search(re.escape(name) + r'(?:(?!\.exe|\.AppImage)[\s\S]){0,200}?\b([0-9A-Fa-f]{64})\b', text)
    if not found or not url.startswith('https://'):
        return 1
    print(url, found.group(1).lower())
    return 0


def dotnet_link(list_path):
    """Prints the link and the SHA-512 of the newest Desktop Runtime installer in Microsoft's release
    list. Returns 1 when the list names none."""
    for release in json.loads(read_bytes(list_path))['releases']:   # newest first
        for file in (release.get('windowsdesktop') or {}).get('files') or []:
            url, checksum = file.get('url', ''), file.get('hash', '')
            if file.get('name') == 'windowsdesktop-runtime-win-x64.exe' and url.startswith('https://') and re.fullmatch('[0-9A-Fa-f]{128}', checksum):
                print(url, checksum.lower())
                return 0
    return 1


# each command with the fewest and the most arguments it takes
COMMANDS = {
    'page-link': (page_link, 3, 3),
    'dotnet-link': (dotnet_link, 1, 1),
    'get-env': (get_env, 2, 2),
    'set-env': (set_env, 2, None),
    'unset-env': (unset_env, 2, None),
    'get-option': (get_option, 2, 2),
    'set-options': (set_options, 2, 3),
    'video-off': (video_off, 1, 1),
}


def main(arguments):
    name, rest = (arguments[0] if arguments else ''), arguments[1:]
    if name not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    command, fewest, most = COMMANDS[name]
    if len(rest) < fewest or (most is not None and len(rest) > most):
        print('%s: wrong number of arguments. Run setup-helpers.py without arguments for the list' % name, file=sys.stderr)
        return 2
    try:
        return command(*rest) or 0
    except (OSError, ValueError, KeyError) as error:
        print('%s: %s' % (name, error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
