#!/usr/bin/env python3
"""check-rules.py

The rules of STYLEGUIDE.md that a script can check: no semicolons in prose, comments and messages,
and one list of setup steps in every place that writes it out. Prints what it finds and fails if
there is anything."""
import re
import subprocess
import sys

HASH_COMMENTS = ('.sh', '.py', '.s', '.toml', '.yml', '.shellcheckrc', '.gitignore')
SLASH_COMMENTS = ('.cpp', '.h', '.rs', '.inc')
SHELL_MESSAGE = re.compile(r'"((?:[^"\\]|\\.)*)"')
WORD_AFTER_SEMICOLON = re.compile(r'[\w)\'.]; +[A-Za-z]')


def tracked_files():
    return subprocess.run(['git', 'ls-files'], capture_output=True, text=True, check=True).stdout.split('\n')[:-1]


def lines_of(path):
    with open(path, encoding='utf-8', errors='replace') as file:
        return file.read().split('\n')


def prose_of(lines):
    """The lines of a Markdown file outside code blocks, with inline code taken out."""
    in_code = False
    for number, line in enumerate(lines, 1):
        if line.startswith('```'):
            in_code = not in_code
        elif not in_code:
            yield number, re.sub(r'`[^`]*`', '', line)


def hash_comment(line):
    whole = re.match(r'^\s*#(?!!)(.*)$', line)
    trailing = re.search(r'\s{2,}#\s(.*)$', line)
    found = whole or trailing
    return found.group(1) if found else ''


def slash_comment(line):
    found = re.search(r'(?<!:)//(.*)$', line)
    return found.group(1) if found else ''


def comment_of(path, line):
    if path.endswith('.patch'):
        return slash_comment(line) if line.startswith('+') and not line.startswith('+++') else ''
    if path.endswith(HASH_COMMENTS):
        return hash_comment(line)
    if path.endswith(SLASH_COMMENTS):
        return slash_comment(line)
    return ''


def messages_of(path, line):
    """The texts a shell script prints: its double-quoted strings that are not commands."""
    if not path.endswith('.sh'):
        return []
    return [text for text in SHELL_MESSAGE.findall(line) if '$(' not in text]


def semicolons(path):
    lines = lines_of(path)
    if path.endswith('.md'):
        return [(number, 'prose') for number, text in prose_of(lines) if ';' in text]
    found = []
    for number, line in enumerate(lines, 1):
        if ';' in comment_of(path, line):
            found.append((number, 'comment'))
        elif any(WORD_AFTER_SEMICOLON.search(text) for text in messages_of(path, line)):
            found.append((number, 'message'))
    return found


def step_lists():
    """The setup's steps as each place lists them. The docs describe uninstall in a section of its own."""
    setup = '\n'.join(lines_of('scripts/setup.sh'))
    installer = '\n'.join(lines_of('install.sh'))
    building = '\n'.join(lines_of('docs/building.md'))
    help_text = setup.split('# Steps:\n', 1)[1].split('\n#\n', 1)[0]
    return {
        'the help text of scripts/setup.sh': set(re.findall(r'^#   ([a-z]+) ', help_text, re.M)),
        'the arguments of scripts/setup.sh': set(re.search(r'^\s+([a-z|]+)\) STEPS=', setup, re.M).group(1).split('|')),
        'the step functions of scripts/setup.sh': set(re.findall(r'^step_([a-z]+)\(\)', setup, re.M)),
        'the arguments install.sh passes on': set(re.search(r'-h\|([a-z|]+)\) set --', installer).group(1).split('|')),
        'the list in docs/building.md': set(re.findall(r'^\d+\. \*\*([a-z]+)\*\*', building, re.M)) | {'uninstall'},
    }


def main():
    problems = []
    for path in tracked_files():
        if path.endswith(('.jpg', '.png', '.list')):
            continue
        problems += ['%s:%d: a semicolon in a %s' % (path, number, kind) for number, kind in semicolons(path)]
    lists = step_lists()
    reference_name, reference = next(iter(lists.items()))
    for name, steps in lists.items():
        if steps != reference:
            problems.append('%s names other steps than %s: %s' % (name, reference_name, ' '.join(sorted(steps ^ reference))))
    print('\n'.join(problems) if problems else 'writing rules and step lists: nothing found')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
