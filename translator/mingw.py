"""Starts the mingw-w64 tools for the translator's scripts and reads what they print.

The one place that calls objdump: its temporary file, its command line and the format of its lines."""
import os
import re
import subprocess
import tempfile

from peimage import Fail

OBJDUMP = 'i686-w64-mingw32-objdump'
NM = 'i686-w64-mingw32-nm'

# Code handed to objdump is the game's. It goes under build/ like everything made from the game, when that folder exists.
BUILD_FOLDER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build')

INSTRUCTION_LINE = re.compile(r'^\s*([0-9a-f]+):\t((?:[0-9a-f]{2} )+)\s*(?:\t(.*))?$')


def run(command):
    """What a tool prints. The tool has to exist and to end without an error."""
    try:
        done = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise Fail('cannot start %s: %s' % (command[0], error)) from error
    if done.returncode:
        raise Fail('%s ended with status %d: %s' % (command[0], done.returncode, done.stderr.strip()))
    return done.stdout


def disassembly(code, address, wide=True, zero_runs=False):
    """The lines objdump prints for code that sits at address, one at a time.

    wide keeps every instruction on one line. zero_runs prints runs of zero bytes, which objdump otherwise
    leaves out. Raises Fail if objdump cannot be started or ends with an error."""
    folder = BUILD_FOLDER if os.path.isdir(BUILD_FOLDER) else None
    file = tempfile.NamedTemporaryFile(prefix='objdump-', suffix='.bin', dir=folder, delete=False)
    try:
        with file:
            file.write(code)
        command = [OBJDUMP, '-D', '-b', 'binary', '-mi386', '-Mintel', '--adjust-vma=0x%x' % address]
        if wide:
            command.append('--insn-width=16')
        if zero_runs:
            command.append('-z')
        # the error text goes to a file of its own, so a tool that complains a lot cannot block on a full pipe
        with tempfile.TemporaryFile(mode='w+') as errors:
            try:
                process = subprocess.Popen(command + [file.name], stdout=subprocess.PIPE, stderr=errors, text=True)
            except OSError as error:
                raise Fail('cannot start %s: %s' % (OBJDUMP, error)) from error
            try:
                yield from process.stdout
                status = process.wait()
            finally:
                if process.poll() is None:      # the reader stopped early
                    process.kill()
                    process.wait()
                process.stdout.close()
            if status:
                errors.seek(0)
                raise Fail('%s ended with status %d: %s' % (OBJDUMP, status, errors.read().strip()))
    finally:
        os.unlink(file.name)


def instruction(line):
    """(address, bytes, text) of a line that holds an instruction, None for every other line."""
    found = INSTRUCTION_LINE.match(line)
    if not found:
        return None
    return int(found.group(1), 16), bytes.fromhex(found.group(2).replace(' ', '')), (found.group(3) or '').strip()
