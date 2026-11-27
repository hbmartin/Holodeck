"""Exercise the release script with local archives and stubbed upload tools."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest


MOCK_TOOL = textwrap.dedent('''\
    #!/usr/bin/env python3
    import os
    from pathlib import Path
    import plistlib
    import sys

    args = sys.argv[1:]
    tool = Path(sys.argv[0]).name

    def value(option):
        return args[args.index(option) + 1]

    def record(*fields):
        with open(os.environ['DISTRIBUTION_TEST_LOG'], 'a') as log:
            print(*fields, file=log)

    def setting(name):
        return next(arg.split('=', 1)[1] for arg in args if arg.startswith(name + '='))

    if tool == 'xcodebuild' and '-exportArchive' in args:
        archive = Path(value('-archivePath'))
        options = plistlib.loads(Path(value('-exportOptionsPlist')).read_bytes())
        assert options['method'] == 'app-store-connect'
        assert options['destination'] == 'upload'
        assert not options['manageAppVersionAndBuildNumber']
        assert options['uploadSymbols']
        assert 'SENTRY_AUTH_TOKEN' not in os.environ
        record('apple', archive.stem, options['testFlightInternalTestingOnly'])
        if os.environ.get('DISTRIBUTION_TEST_APPLE_FAILURE') == archive.stem:
            sys.exit(1)
    elif tool == 'xcodebuild':
        scheme, config, destination = map(value, ('-scheme', '-configuration', '-destination'))
        record('archive', scheme, config, destination)
        assert 'SENTRY_AUTH_TOKEN' not in os.environ
        if os.environ.get('DISTRIBUTION_TEST_ARCHIVE_FAILURE') == scheme:
            sys.exit(1)
        archive = Path(value('-archivePath'))
        app = archive / 'Products' / 'Applications' / f'{scheme}.app'
        if scheme == 'HolodeckMac':
            app /= 'Contents'
        app.mkdir(parents=True)
        info = {'CFBundleIdentifier': f'me.haroldmartin.{scheme}', 'CFBundleExecutable': scheme,
                'CFBundleVersion': setting('CURRENT_PROJECT_VERSION'), 'CFBundleShortVersionString': '1.0',
                'DTPlatformName': 'macosx' if scheme == 'HolodeckMac' else 'appletvos',
                'HolodeckSentryDSN': setting('HOLODECK_SENTRY_DSN'),
                'HolodeckSentryEnvironment': setting('HOLODECK_SENTRY_ENVIRONMENT')}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        if scheme == 'HolodeckMac':
            app /= 'MacOS'
            app.mkdir()
        (app / scheme).touch()
        if os.environ.get('DISTRIBUTION_TEST_MISSING_DSYM') != '1':
            dsym = archive / 'dSYMs' / f'{scheme}.app.dSYM' / 'Contents' / 'Resources' / 'DWARF'
            dsym.mkdir(parents=True)
            (dsym / scheme).touch()
    elif tool == 'codesign':
        if '--display' in args:
            assert '--xml' in args
            sys.stdout.buffer.write(plistlib.dumps({'com.apple.security.app-sandbox': True}))
        else:
            assert args[:2] == ['--verify', '--strict']
    elif tool == 'xcrun':
        assert args[:2] == ['dwarfdump', '--uuid']
        uuid = '12345678-1234-1234-1234-123456789abc'
        if '.dSYM/' in args[2] and os.environ.get('DISTRIBUTION_TEST_MISMATCH') == '1':
            uuid = '87654321-1234-1234-1234-123456789abc'
        print(f'UUID: {uuid} (arm64) {args[2]}')
    elif tool == 'sentry-cli':
        assert args[:2] == ['debug-files', 'upload']
        assert '--wait' in args and '--no-sources' in args
        assert 'SENTRY_ALLOW_FAILURE' not in os.environ
        record('sentry', value('--org'), value('--project'), Path(args[-1]).parent.stem)
        sys.exit(int(os.environ.get('DISTRIBUTION_TEST_SENTRY_STATUS', '0')))
    else:
        sys.exit('Unexpected test tool')
    ''')


class DistributionTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='Holodeck distribution ')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        tools = self.root / 'tools'
        tools.mkdir()
        self.script = tools / 'distribute.sh'
        shutil.copy(Path(__file__).with_name('distribute.sh'), self.script)
        for tool in ('xcodebuild', 'xcrun', 'codesign', 'sentry-cli'):
            path = tools / tool
            path.write_text(MOCK_TOOL, encoding='utf-8')
            path.chmod(0o755)
        self.log = self.root / 'test.log'
        key = self.root / 'test key.p8'
        key.touch()
        self.environment = {
            'PATH': os.pathsep.join((str(tools), os.environ['PATH'])),
            'DISTRIBUTION_TEST_LOG': str(self.log),
            'ASC_KEY_PATH': str(key), 'ASC_KEY_ID': 'KEY', 'ASC_ISSUER_ID': 'ISSUER',
            'SENTRY_ORG': 'holodeck', 'SENTRY_AUTH_TOKEN': 'test-token', 'SENTRY_ALLOW_FAILURE': '1',
            'SENTRY_DSN_TVOS': 'https://public@example.invalid/1', 'SENTRY_PROJECT_TVOS': 'tv',
            'SENTRY_DSN_MACOS': 'https://public@example.invalid/2', 'SENTRY_PROJECT_MACOS': 'mac',
        }

    def run_release(self, *arguments, success=True):
        result = subprocess.run(['/bin/bash', str(self.script), *arguments], cwd=self.root,
                                env=self.environment, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stderr

    def calls(self):
        return self.log.read_text(encoding='utf-8').splitlines() if self.log.exists() else []

    def test_both_apps_upload_symbols_then_the_same_archive(self):
        self.run_release('all', '--build-number', '42', '--internal-only')
        self.assertEqual(self.calls(), [
            'archive Holodeck Release generic/platform=tvOS', 'archive HolodeckMac TestFlight generic/platform=macOS',
            'sentry holodeck tv Holodeck', 'apple Holodeck True', 'sentry holodeck mac HolodeckMac', 'apple HolodeckMac True',
        ])

    def test_mac_archive_failure_prevents_both_uploads(self):
        self.environment['DISTRIBUTION_TEST_ARCHIVE_FAILURE'] = 'HolodeckMac'
        message = self.run_release('all', '--build-number', '42', success=False)
        self.assertIn('Archiving HolodeckMac failed', message)
        self.assertEqual(self.calls(), ['archive Holodeck Release generic/platform=tvOS',
                                        'archive HolodeckMac TestFlight generic/platform=macOS'])

    def test_partial_upload_prints_a_mac_only_retry_for_the_same_archive(self):
        self.environment['DISTRIBUTION_TEST_APPLE_FAILURE'] = 'HolodeckMac'
        message = self.run_release('all', '--build-number', '42', '--internal-only', success=False)
        self.assertIn('Submitted to App Store Connect: tvos', message)
        self.assertIn('already received macos before retrying', message)
        archive, = self.root.glob('.build/distribution/*/HolodeckMac.xcarchive')
        command, = (shlex.split(line) for line in message.splitlines() if line.startswith('  '))
        self.assertEqual(command, [str(self.script.resolve()), 'macos', '--archive', str(archive.resolve()), '--internal-only'])
        del self.environment['DISTRIBUTION_TEST_APPLE_FAILURE']
        self.run_release(*command[1:])
        self.assertEqual(self.calls().count('apple Holodeck True'), 1)
        self.assertEqual(self.calls().count('archive HolodeckMac TestFlight generic/platform=macOS'), 1)
        self.assertEqual(self.calls()[-1], 'apple HolodeckMac True')

    def test_first_upload_failure_lists_both_verified_archives(self):
        self.environment['DISTRIBUTION_TEST_SENTRY_STATUS'] = '1'
        message = self.run_release('all', '--build-number', '42', success=False)
        self.assertIn('No platform submission was confirmed', message)
        commands = [shlex.split(line) for line in message.splitlines() if line.startswith('  ')]
        self.assertEqual([command[1:3] for command in commands], [['tvos', '--archive'], ['macos', '--archive']])
        self.assertTrue(all(Path(command[3]).is_dir() for command in commands))
        self.assertEqual(self.calls()[-1], 'sentry holodeck tv Holodeck')

    def test_missing_configuration_for_second_app_prevents_both_uploads(self):
        del self.environment['SENTRY_PROJECT_MACOS']
        self.assertIn('SENTRY_PROJECT_MACOS', self.run_release('all', '--build-number', '42', success=False))
        self.assertEqual(self.calls(), [])

    def test_missing_or_mismatched_dsym_prevents_uploads(self):
        for variable, error in [('DISTRIBUTION_TEST_MISSING_DSYM', 'Missing app executable or dSYM'),
                                ('DISTRIBUTION_TEST_MISMATCH', 'UUIDs do not match')]:
            with self.subTest(variable=variable):
                self.environment[variable] = '1'
                try:
                    self.assertIn(error, self.run_release('tvos', '--build-number', '42', success=False))
                    self.assertEqual(self.calls(), ['archive Holodeck Release generic/platform=tvOS'])
                finally:
                    del self.environment[variable]
                    self.log.unlink(missing_ok=True)

    def test_archive_only_and_retry_preserve_the_archive(self):
        upload_settings = {key: self.environment.pop(key) for key in
                           ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'SENTRY_AUTH_TOKEN')}
        self.run_release('macos', '--build-number', '42', '--archive-only')
        self.assertEqual(self.calls(), ['archive HolodeckMac TestFlight generic/platform=macOS'])
        self.environment.update(upload_settings)
        archive, = self.root.glob('.build/distribution/*/HolodeckMac.xcarchive')
        self.environment['DISTRIBUTION_TEST_SENTRY_STATUS'] = '1'
        self.assertIn('dSYMs to Sentry failed', self.run_release('macos', '--archive', str(archive), success=False))
        self.assertEqual(self.calls()[-1], 'sentry holodeck mac HolodeckMac')
        del self.environment['DISTRIBUTION_TEST_SENTRY_STATUS']
        self.run_release('macos', '--archive', str(archive) + '/')
        self.assertEqual(self.calls(), ['archive HolodeckMac TestFlight generic/platform=macOS',
                                       'sentry holodeck mac HolodeckMac', 'sentry holodeck mac HolodeckMac',
                                       'apple HolodeckMac False'])


if __name__ == '__main__':
    unittest.main()
