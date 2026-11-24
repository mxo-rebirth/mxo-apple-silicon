#!/usr/bin/env python3
"""test_setup_helpers.py

Tests scripts/setup-helpers.py on temporary files. Needs neither the game nor CrossOver:

    python3 -I tests/setup/test_setup_helpers.py
"""

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

HELPERS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts', 'setup-helpers.py')
spec = importlib.util.spec_from_file_location('setup_helpers', HELPERS)
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

CONF = (
    ';; a comment that names [EnvironmentVariables] is not the section\n'
    '[Bottle]\n'
    '"Description" = "The Matrix Online"\n'
    '"DXVK_HUD" = "in another section"\n'
    '[EnvironmentVariables]\n'
    '"WINEMSYNC" = "1"\n'
    ';;"PROMPT" = "$p$g"\n'
    '[Other]\n'
    '"Last" = "1"\n'
)


def printed(function, *arguments):
    """What FUNCTION prints, without the line end."""
    out = io.StringIO()
    with redirect_stdout(out):
        function(*arguments)
    return out.getvalue().rstrip('\n')


class WithFolder(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def file(self, name, content=None):
        path = os.path.join(self.folder.name, name)
        if content is not None:
            with open(path, 'wb') as file:
                file.write(content if isinstance(content, bytes) else content.encode('utf-8'))
        return path

    def read(self, path):
        with open(path, 'rb') as file:
            return file.read()

    def assert_nothing_left_over(self):
        self.assertEqual([name for name in os.listdir(self.folder.name) if name.endswith('.new')], [])


class Environment(WithFolder):
    def test_a_new_variable_goes_under_the_section_header(self):
        conf = self.file('cxbottle.conf', CONF)
        helpers.set_env(conf, 'DXVK_LOG_PATH=C:/Games/dxvk')
        lines = self.read(conf).decode().split('\n')
        self.assertEqual(lines[lines.index('[EnvironmentVariables]') + 1], '"DXVK_LOG_PATH" = "C:/Games/dxvk"')
        self.assertEqual(printed(helpers.get_env, conf, 'DXVK_LOG_PATH'), 'C:/Games/dxvk')
        self.assert_nothing_left_over()

    def test_only_the_section_counts(self):
        conf = self.file('cxbottle.conf', CONF)
        self.assertEqual(printed(helpers.get_env, conf, 'DXVK_HUD'), '')
        helpers.set_env(conf, 'DXVK_HUD=fps')
        self.assertIn(b'"DXVK_HUD" = "in another section"\n', self.read(conf))
        self.assertEqual(printed(helpers.get_env, conf, 'DXVK_HUD'), 'fps')
        helpers.unset_env(conf, 'DXVK_HUD', 'Last')
        self.assertIn(b'"DXVK_HUD" = "in another section"\n', self.read(conf))
        self.assertIn(b'"Last" = "1"\n', self.read(conf))
        self.assertEqual(printed(helpers.get_env, conf, 'DXVK_HUD'), '')

    def test_a_value_is_replaced_also_with_backslashes_in_it(self):
        conf = self.file('cxbottle.conf', CONF)
        helpers.set_env(conf, r'DXVK_LOG_PATH=C:\Games\dxvk')
        helpers.set_env(conf, r'DXVK_LOG_PATH=C:\Games\other', 'WINEMSYNC=0')
        self.assertEqual(printed(helpers.get_env, conf, 'DXVK_LOG_PATH'), r'C:\Games\other')
        self.assertEqual(printed(helpers.get_env, conf, 'WINEMSYNC'), '0')
        self.assertEqual(self.read(conf).count(b'DXVK_LOG_PATH'), 1)

    def test_names_are_matched_exactly(self):
        conf = self.file('cxbottle.conf', CONF)
        helpers.set_env(conf, 'winemsync=0')
        self.assertEqual(printed(helpers.get_env, conf, 'WINEMSYNC'), '1')
        self.assertEqual(printed(helpers.get_env, conf, 'winemsync'), '0')

    def test_windows_line_ends_stay(self):
        conf = self.file('cxbottle.conf', CONF.replace('\n', '\r\n'))
        helpers.set_env(conf, 'A=1')
        helpers.set_env(conf, 'WINEMSYNC=0')
        self.assertEqual(self.read(conf), CONF.replace('"WINEMSYNC" = "1"', '"A" = "1"\n"WINEMSYNC" = "0"').replace('\n', '\r\n').encode())

    def test_a_header_at_the_very_end_of_the_file(self):
        conf = self.file('cxbottle.conf', '[Bottle]\n"A" = "1"\n[EnvironmentVariables]')
        helpers.set_env(conf, 'B=2')
        self.assertEqual(self.read(conf), b'[Bottle]\n"A" = "1"\n[EnvironmentVariables]\n"B" = "2"\n')

    def test_a_missing_section_is_added(self):
        conf = self.file('cxbottle.conf', '[Bottle]\n"A" = "1"\n\n\n')
        helpers.set_env(conf, 'B=2', 'C=3')
        self.assertEqual(self.read(conf), b'[Bottle]\n"A" = "1"\n\n[EnvironmentVariables]\n"C" = "3"\n"B" = "2"\n')

    def test_unset_removes_every_line_of_the_name(self):
        conf = self.file('cxbottle.conf', CONF.replace('"WINEMSYNC" = "1"\n', '"WINEMSYNC" = "1"\n"X" = "1"\n "X"="2"\n'))
        self.assertEqual(printed(helpers.get_env, conf, 'X'), '2')
        helpers.unset_env(conf, 'X', 'NOT_THERE')
        self.assertEqual(self.read(conf).decode(), CONF)

    def test_nothing_to_do_leaves_the_file_alone(self):
        conf = self.file('cxbottle.conf', CONF.rstrip('\n'))
        helpers.set_env(conf, 'WINEMSYNC=1')
        helpers.unset_env(conf, 'NOT_THERE')
        self.assertEqual(self.read(conf).decode(), CONF.rstrip('\n'))

    def test_bytes_that_are_not_utf8_stay(self):
        conf = self.file('cxbottle.conf', b'[Bottle]\n"Description" = "caf\xe9"\n[EnvironmentVariables]\n')
        helpers.set_env(conf, 'A=1')
        self.assertIn(b'"caf\xe9"', self.read(conf))

    def test_a_failed_write_leaves_the_old_file_whole(self):
        conf = self.file('cxbottle.conf', CONF)
        replace = os.replace

        def refuse(source, target):
            raise OSError('no space left')
        os.replace = refuse
        try:
            with self.assertRaises(OSError):
                helpers.set_env(conf, 'A=1')
        finally:
            os.replace = replace
        self.assertEqual(self.read(conf).decode(), CONF)
        self.assert_nothing_left_over()


class Settings(WithFolder):
    def test_a_new_file_has_windows_line_ends(self):
        cfg = self.file('dxvk.conf')
        helpers.set_options(cfg, 'd3d9.samplerAnisotropy = 16')
        self.assertEqual(self.read(cfg), b'd3d9.samplerAnisotropy = 16\r\n')

    def test_keys_match_in_any_case_and_keep_their_spelling(self):
        cfg = self.file('options.cfg', 'First = 1\n  musicsystemenable=0\nLast = 3\n')
        helpers.set_options(cfg, '\nMusicSystemEnable = 1\nNew = 4\n')
        self.assertEqual(self.read(cfg), b'First = 1\nmusicsystemenable = 1\nLast = 3\nNew = 4\n')
        self.assertEqual(printed(helpers.get_option, cfg, 'MUSICSYSTEMENABLE'), '1')

    def test_every_line_of_a_key_gets_the_value(self):
        cfg = self.file('options.cfg', 'A = 1\r\nB = 2\r\na = 3\r\n')
        helpers.set_options(cfg, 'A = 9')
        self.assertEqual(self.read(cfg), b'A = 9\r\nB = 2\r\na = 9\r\n')

    def test_existing_only_adds_nothing(self):
        cfg = self.file('useropts.cfg', 'A = 1\n')
        helpers.set_options('--existing', cfg, 'A = 2\nB = 3')
        self.assertEqual(self.read(cfg), b'A = 2\n')
        missing = self.file('missing.cfg')
        helpers.set_options('--existing', missing, 'A = 2')
        self.assertFalse(os.path.exists(missing))

    def test_the_end_of_the_file_is_one_line_end(self):
        cfg = self.file('options.cfg', 'A = 1\r\nB = 2\r\n\r\n\r\n')
        helpers.set_options(cfg, 'C = 3')
        self.assertEqual(self.read(cfg), b'A = 1\r\nB = 2\r\nC = 3\r\n')
        cfg = self.file('other.cfg', 'A = 1\r\nB = 2')
        helpers.set_options(cfg, 'C = 3')
        self.assertEqual(self.read(cfg), b'A = 1\r\nB = 2\r\nC = 3\r\n')

    def test_an_unchanged_file_is_not_written(self):
        cfg = self.file('options.cfg', 'A = 1\n\n\n')
        helpers.set_options(cfg, 'A = 1')
        self.assertEqual(self.read(cfg), b'A = 1\n\n\n')

    def test_other_bytes_and_a_byte_order_mark_stay(self):
        cfg = self.file('MxORevived-audio.txt', b'\xef\xbb\xbfname = caf\xe9\r\nmusic = off\r\n')
        self.assertEqual(printed(helpers.get_option, cfg, 'music'), 'off')
        helpers.set_options(cfg, 'music = on')
        self.assertEqual(self.read(cfg), b'\xef\xbb\xbfname = caf\xe9\r\nmusic = on\r\n')

    def test_a_missing_file_has_no_options(self):
        self.assertEqual(printed(helpers.get_option, self.file('missing.cfg'), 'music'), '')


class Video(WithFolder):
    def test_true_becomes_false_and_the_rest_stays(self):
        text = b'\xef\xbb\xbf{\r\n  "Name": "caf\xc3\xa9",\r\n  "BackgroundVideo" : true\r\n}'
        settings = self.file('launcher-settings.json', text)
        helpers.video_off(settings)
        self.assertEqual(self.read(settings), text.replace(b'true', b'false'))
        helpers.video_off(settings)
        self.assertEqual(self.read(settings), text.replace(b'true', b'false'))

    def test_a_missing_key_is_added(self):
        settings = self.file('launcher-settings.json', '{"Server": "one"}')
        helpers.video_off(settings)
        self.assertEqual(json.loads(self.read(settings)), {'Server': 'one', 'BackgroundVideo': False})

    def test_a_file_that_is_not_json_stays_as_it_is(self):
        settings = self.file('launcher-settings.json', 'not json')
        with self.assertRaises(ValueError):
            helpers.video_off(settings)
        self.assertEqual(self.read(settings), b'not json')
        self.assert_nothing_left_over()

    def test_a_link_in_place_of_the_new_file_is_not_written_through(self):
        outside = self.file('outside.txt', 'untouched')
        settings = self.file('launcher-settings.json', '{"BackgroundVideo": true}')
        os.symlink(outside, settings + '.new')
        helpers.video_off(settings)
        self.assertEqual(self.read(outside), b'untouched')
        self.assertEqual(json.loads(self.read(settings)), {'BackgroundVideo': False})


class Pages(WithFolder):
    CHECKSUM = 'AB' * 32
    PAGE = (
        '<html><style>a { color: red }</style><body>'
        '<a href="/files/launcher-1.2.3-win64.exe">Windows</a>'
        '<p>launcher-1.2.3-win64.exe<br>SHA-256: <code>%s</code></p>'
        '<a href="/files/launcher-1.2.3.AppImage">Linux</a> launcher-1.2.3.AppImage %s'
        '</body></html>'
    ) % (CHECKSUM, 'CD' * 32)

    def test_the_link_and_the_checksum_after_its_name(self):
        page = self.file('page.html', self.PAGE)
        out = io.StringIO()
        with redirect_stdout(out):
            status = helpers.page_link(page, 'https://example.org/download', r'launcher-[0-9.]+-win64\.exe')
        self.assertEqual(status, 0)
        self.assertEqual(out.getvalue(), 'https://example.org/files/launcher-1.2.3-win64.exe %s\n' % self.CHECKSUM.lower())

    def test_no_link_no_checksum_or_no_https(self):
        page = self.file('page.html', self.PAGE)
        self.assertEqual(helpers.page_link(page, 'https://example.org/', r'other\.exe'), 1)
        self.assertEqual(helpers.page_link(page, 'http://example.org/', r'launcher-[0-9.]+-win64\.exe'), 1)
        bare = self.file('bare.html', self.PAGE.replace(self.CHECKSUM, 'none'))
        self.assertEqual(helpers.page_link(bare, 'https://example.org/', r'launcher-[0-9.]+-win64\.exe'), 1)

    def test_unclosed_blocks_take_no_long(self):
        page = self.file('page.html', '<script ' * 200000 + '<' * 200000 + self.PAGE)
        started = time.monotonic()
        self.assertEqual(helpers.page_link(page, 'https://example.org/', r'launcher-[0-9.]+-win64\.exe'), 1)
        self.assertLess(time.monotonic() - started, 5)

    def test_a_script_block_hides_its_text(self):
        page = self.file('page.html', self.PAGE.replace('<p>', '<SCRIPT>var x = "launcher-1.2.3-win64.exe %s"</script><p>' % ('EE' * 32)))
        out = io.StringIO()
        with redirect_stdout(out):
            helpers.page_link(page, 'https://example.org/', r'launcher-[0-9.]+-win64\.exe')
        self.assertIn(self.CHECKSUM.lower(), out.getvalue())

    def test_a_letter_whose_small_form_is_longer_moves_nothing(self):
        self.assertEqual(helpers.without_scripts('\u0130\u0130 a <SCRIPT>x</script> b <style>y</STYLE> c'),
                         '\u0130\u0130 a  </script> b  </STYLE> c')

    def test_the_newest_desktop_runtime(self):
        wanted = {'name': 'windowsdesktop-runtime-win-x64.exe', 'url': 'https://example.org/new.exe', 'hash': 'EF' * 64}
        releases = {'releases': [
            {'windowsdesktop': None},
            {'windowsdesktop': {'files': [{'name': 'windowsdesktop-runtime-win-x86.exe', 'url': 'https://example.org/x86.exe', 'hash': '0' * 128}, wanted]}},
            {'windowsdesktop': {'files': [dict(wanted, url='https://example.org/old.exe')]}},
        ]}
        out = io.StringIO()
        with redirect_stdout(out):
            status = helpers.dotnet_link(self.file('releases.json', json.dumps(releases)))
        self.assertEqual((status, out.getvalue()), (0, 'https://example.org/new.exe %s\n' % ('ef' * 64)))
        self.assertEqual(helpers.dotnet_link(self.file('none.json', '{"releases": []}')), 1)


class CommandLine(WithFolder):
    def run_helper(self, *arguments, **options):
        return subprocess.run([sys.executable, '-I', HELPERS] + list(arguments), capture_output=True, **options)

    def test_a_command_edits_and_prints(self):
        conf = self.file('cxbottle.conf', CONF)
        self.assertEqual(self.run_helper('set-env', conf, 'A=1', 'B=2').returncode, 0)
        done = self.run_helper('get-env', conf, 'B')
        self.assertEqual((done.returncode, done.stdout), (0, b'2\n'))

    def test_a_page_comes_from_standard_input(self):
        done = self.run_helper('page-link', '-', 'https://example.org/', r'launcher-[0-9.]+-win64\.exe', input=Pages.PAGE.encode())
        self.assertEqual(done.returncode, 0)
        self.assertTrue(done.stdout.startswith(b'https://example.org/files/launcher-1.2.3-win64.exe '))
        self.assertEqual(self.run_helper('page-link', '-', 'https://example.org/', r'other\.exe', input=b'').returncode, 1)

    def test_a_failure_is_one_line_and_status_1(self):
        done = self.run_helper('set-env', self.file('missing.conf'), 'A=1')
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stderr.count(b'\n'), 1)
        self.assertTrue(done.stderr.startswith(b'set-env: '))
        done = self.run_helper('dotnet-link', self.file('list.json', 'not json'))
        self.assertEqual((done.returncode, done.stderr.count(b'\n')), (1, 1))

    def test_wrong_use_is_status_2(self):
        self.assertEqual(self.run_helper().returncode, 2)
        self.assertEqual(self.run_helper('no-such-command').returncode, 2)
        self.assertEqual(self.run_helper('get-env', 'only-one').returncode, 2)
        self.assertEqual(self.run_helper('set-options', '--existing', 'file').returncode, 1)


if __name__ == '__main__':
    unittest.main()
