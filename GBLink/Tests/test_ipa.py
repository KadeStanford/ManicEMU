import hashlib
import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest
import zipfile

SCRIPT = pathlib.Path(__file__).parents[1] / 'scripts' / 'ipa_link.py'
spec = importlib.util.spec_from_file_location('ipa_link', SCRIPT)
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)


def macho(filetype=2, encrypted=False, padding=True):
    data = bytearray(1024)
    count, size = 2, 176
    if encrypted:
        count += 1
        size += 24
    struct.pack_into('<8I', data, 0, 0xFEEDFACF, ipa.ARM64, 0, filetype, count, size, 0, 0)
    struct.pack_into('<II', data, 32, 0x19, 152)
    struct.pack_into('<QQ', data, 72, 0, len(data))
    struct.pack_into('<I', data, 96, 1)
    struct.pack_into('<Q', data, 144, 512)
    struct.pack_into('<I', data, 152, 512 if padding else 32 + size)
    struct.pack_into('<6I', data, 184, 0x32, 24, 2, 15 << 16, 15 << 16, 0)
    if encrypted:
        struct.pack_into('<6I', data, 208, 0x2c, 24, 512, 512, 1, 0)
    data[512:] = b'x' * 512
    return bytes(data)


class IPATests(unittest.TestCase):
    def test_load_command_preserves_code_and_rejects_second_patch(self):
        before = macho()
        after = ipa.patch_macho(before)
        self.assertEqual(before[512:], after[512:])
        self.assertIn(ipa.LOAD_PATH, ipa.inspect_slice(after)['load_paths'])
        with self.assertRaisesRegex(ValueError, 'already'):
            ipa.patch_macho(after)

    def test_blockers(self):
        for data, reason in [(macho(encrypted=True), 'Encrypted application'),
                             (macho(padding=False), 'padding'),
                             (b'not macho', 'Mach-O')]:
            with self.assertRaisesRegex(ValueError, reason):
                ipa.patch_macho(data)
        wrong = bytearray(macho()); struct.pack_into('<I', wrong, 4, 7)
        with self.assertRaisesRegex(ValueError, 'arm64'):
            ipa.patch_macho(wrong)

    def test_repackage_preserves_input_save_capabilities_and_unrelated_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'original.ipa'; out = root / 'new.ipa'
            framework = root / 'ManicGBLink.framework'; framework.mkdir()
            (framework / 'ManicGBLink').write_bytes(macho(filetype=6))
            (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'ManicGBLink', 'CFBundlePackageType': 'FMWK'}))
            (framework / 'LICENSE').write_text('test license')
            info = {'CFBundleExecutable': 'Manic', 'CFBundleIdentifier': 'test.manic',
                    'NSBonjourServices': ['_ra_netplay._tcp'], 'TestUnrelatedSetting': 'keep'}
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr('Payload/Manic.app/Info.plist', plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
                z.writestr('Payload/Manic.app/Manic', macho())
                z.writestr('Payload/Manic.app/unrelated.txt', b'preserve me')
                z.writestr('Payload/Manic.app/System.core', b'synthetic original resource archive')
                z.writestr('Payload/Manic.app/_CodeSignature/CodeResources', b'invalidated signature')
            checksum = hashlib.sha256(source.read_bytes()).hexdigest()
            ipa.repackage(source, framework, out)
            self.assertEqual(checksum, hashlib.sha256(source.read_bytes()).hexdigest())
            with zipfile.ZipFile(out) as z:
                self.assertEqual(z.read('Payload/Manic.app/unrelated.txt'), b'preserve me')
                self.assertEqual(z.read('Payload/Manic.app/System.core'), b'synthetic original resource archive')
                changed = plistlib.loads(z.read('Payload/Manic.app/Info.plist'))
                self.assertEqual(changed['TestUnrelatedSetting'], 'keep')
                self.assertEqual(changed['CFBundleIdentifier'], 'test.manic')
                self.assertTrue(changed['MGLInjectGBLink'])
                self.assertEqual(changed['MinimumOSVersion'], '15.0')
                self.assertIn('_ra_netplay._tcp', changed['NSBonjourServices'])
                self.assertNotIn('Payload/Manic.app/_CodeSignature/CodeResources', z.namelist())
                self.assertIn('Payload/Manic.app/Frameworks/ManicGBLink.framework/LICENSE', z.namelist())
            with self.assertRaisesRegex(ValueError, 'preserved'):
                ipa.repackage(source, framework, out)
            with self.assertRaisesRegex(ValueError, 'preserved'):
                ipa.repackage(source, framework, source)

    def test_zip_paths_and_duplicates(self):
        for names in [['../escape'], ['/absolute'], ['a\\b'], ['a', 'a']]:
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / 'bad.zip'
                with zipfile.ZipFile(path, 'w') as z:
                    for name in names:
                        item = zipfile.ZipInfo('placeholder')
                        item.filename = name  # Avoid constructor normalization on Windows.
                        z.writestr(item, b'x')
                with zipfile.ZipFile(path) as z, self.assertRaises(ValueError):
                    ipa.checked_entries(z)

    def test_simulator_framework_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); framework = root / 'ManicGBLink.framework'; framework.mkdir()
            binary = bytearray(macho(filetype=6)); struct.pack_into('<I', binary, 192, 7)
            (framework / 'ManicGBLink').write_bytes(binary)
            with self.assertRaisesRegex(ValueError, 'physical iOS'):
                ipa.repackage(root / 'irrelevant.ipa', framework, root / 'new.ipa')


if __name__ == '__main__':
    unittest.main()
