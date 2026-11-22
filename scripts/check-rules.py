#!/usr/bin/env python3
"""check-rules.py

The rules of STYLEGUIDE.md that a script can check: no semicolons in prose, comments, docstrings and
messages, nothing in the shell scripts that the bash of macOS does not know, and one list of setup
steps in every place that writes it out. Prints what it finds and fails if there is anything."""
import ast
import os
import re
import subprocess
import sys

HASH_COMMENTS = ('.sh', '.py', '.s', '.toml', '.yml', '.shellcheckrc', '.gitignore')
SLASH_COMMENTS = ('.cpp', '.h', '.rs', '.inc')
SHELL_MESSAGE = re.compile(r'"((?:[^"\\]|\\.)*)"')
WORD_AFTER_SEMICOLON = re.compile(r'[\w)\'.]; +[A-Za-z]')
# what bash 3.2 does not have, and "bash -n" does not notice
NEWER_BASH = (
    (re.compile(r'\$\{[!#]?[A-Za-z0-9_@*]+(\[[^\]]*\])?(,,?|\^\^?)'), 'a change of case inside ${ }'),
    (re.compile(r'(^|[\s;&|({])(mapfile|readarray)(\s|$)'), 'mapfile or readarray'),
    (re.compile(r'(^|[\s;&|({])(declare|local|typeset)\s+-[A-Za-z]*A'), 'an associative array'),
)
# calls whose texts a person gets to read. print with file= writes a file, which is not a message
PRINTING = ('print', 'exit', 'SystemExit', 'error', 'add_argument', 'ArgumentParser', 'add_parser')
STEP_SOURCES = (
    ('the help text of scripts/setup.sh', 'scripts/setup.sh', None),
    ('the arguments of scripts/setup.sh', 'scripts/setup.sh', r'^\s+([a-z|]+)\) STEPS\+?='),
    ('the step functions of scripts/setup.sh', 'scripts/setup.sh', r'^step_([a-z]+)\(\)'),
    ('the arguments install.sh passes on', 'install.sh', r'-h\|([a-z|]+)\) set --'),
    ('the list in docs/building.md', 'docs/building.md', r'^\d+\. \*\*([a-z]+)\*\*'),
)


def checked_files():
    """The files git tracks and the new ones it would add. A tracked file that was deleted is left out."""
    listed = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], capture_output=True, text=True, check=True)
    return sorted(path for path in set(listed.stdout.split('\n')) if path and os.path.isfile(path))


def lines_of(path):
    with open(path, encoding='utf-8', errors='replace') as file:
        return file.read().split('\n')


def prose_of(lines):
    """The lines of a Markdown file outside code blocks, with inline code taken out. A code block may be
    indented, as inside a list item."""
    in_code = False
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith(('```', '~~~')):
            in_code = not in_code
        elif not in_code:
            yield number, re.sub(r'`[^`]*`', '', line)


def whole_line_comment(line):
    found = re.match(r'^\s*#(?!!)(.*)$', line)
    return found.group(1) if found else ''


def trailing_comment(line):
    return re.search(r'\s{2,}#\s(.*)$', line)


def hash_comment(line):
    trailing = trailing_comment(line)
    return whole_line_comment(line) or (trailing.group(1) if trailing else '')


def slash_comment(line):
    found = re.search(r'(?<!:)//(.*)$', line)
    return found.group(1) if found else ''


def comment_of(path, line):
    if path.endswith('.patch'):
        return slash_comment(line) if line.startswith('+') and not line.startswith('+++') else ''
    if path.endswith('.list'):
        return whole_line_comment(line)
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


def called(call):
    return getattr(call.func, 'id', None) or getattr(call.func, 'attr', None)


def writes_a_file(call):
    """A print whose file= is something else than the terminal's two streams."""
    target = next((keyword.value for keyword in call.keywords if keyword.arg == 'file'), None)
    return target is not None and getattr(target, 'attr', None) not in ('stderr', 'stdout')


def texts_in(nodes):
    for node in nodes:
        for part in ast.walk(node):
            if isinstance(part, ast.Constant) and isinstance(part.value, str):
                yield part


def python_texts(lines):
    """The docstrings of a Python file and the texts it prints or stops with, as (line, kind, text)."""
    try:
        tree = ast.parse('\n'.join(lines))
    except SyntaxError:
        return   # ruff says so
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
                for offset, text in enumerate(first.value.value.split('\n')):
                    yield first.lineno + offset, 'docstring', text
        elif isinstance(node, ast.Call) and called(node) in PRINTING and not writes_a_file(node):
            for part in texts_in(node.args + [keyword.value for keyword in node.keywords]):
                yield part.lineno, 'message', part.value
        elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call):
            for part in texts_in(node.exc.args):
                yield part.lineno, 'message', part.value


def semicolons(path, lines):
    if path.endswith('.md'):
        return [(number, 'prose') for number, text in prose_of(lines) if ';' in text]
    found = []
    for number, line in enumerate(lines, 1):
        if ';' in comment_of(path, line):
            found.append((number, 'comment'))
        elif any(WORD_AFTER_SEMICOLON.search(text) for text in messages_of(path, line)):
            found.append((number, 'message'))
    if path.endswith('.py'):
        for number, kind, text in python_texts(lines):
            if ';' in text if kind == 'docstring' else WORD_AFTER_SEMICOLON.search(text):
                found.append((number, kind))
    return sorted(set(found))


def newer_bash(path, lines):
    """What a shell script uses that bash 3.2 does not have, as (line, what). Comments do not count."""
    if not path.endswith('.sh'):
        return []
    found = []
    for number, line in enumerate(lines, 1):
        if whole_line_comment(line):
            continue
        trailing = trailing_comment(line)
        code = line[:trailing.start()] if trailing else line
        found += [(number, what) for pattern, what in NEWER_BASH if pattern.search(code)]
    return found


def step_lists():
    """The setup's steps as each place lists them, and the places where no list was found. The docs
    describe uninstall in a section of its own."""
    lists, missing = {}, []
    for name, path, pattern in STEP_SOURCES:
        text = '\n'.join(lines_of(path)) if os.path.isfile(path) else ''
        if pattern is None:   # the block of the help text that starts with "# Steps:" and ends with an empty comment line
            text = text.split('# Steps:\n', 1)[1].split('\n#\n', 1)[0] if '# Steps:\n' in text else ''
            pattern = r'^#   ([a-z]+) '
        steps = {step for found in re.findall(pattern, text, re.M) for step in found.split('|')}
        if path == 'docs/building.md' and steps:
            steps.add('uninstall')
        if steps:
            lists[name] = steps
        else:
            missing.append(name)
    return lists, missing


def main():
    problems = []
    for path in checked_files():
        if path.endswith(('.jpg', '.png')):
            continue
        lines = lines_of(path)
        problems += ['%s:%d: a semicolon in a %s' % (path, number, kind) for number, kind in semicolons(path, lines)]
        problems += ['%s:%d: %s, which bash 3.2 does not have' % (path, number, what) for number, what in newer_bash(path, lines)]
    lists, missing = step_lists()
    problems += ['%s: no list of the setup steps found there' % name for name in missing]
    if lists:
        reference_name, reference = next(iter(lists.items()))
        for name, steps in lists.items():
            if steps != reference:
                problems.append('%s names other steps than %s: %s' % (name, reference_name, ' '.join(sorted(steps ^ reference))))
    print('\n'.join(problems) if problems else 'writing rules, bash 3.2 and step lists: nothing found')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
