import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('settings', Path(__file__).parents[1] / 'settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

class SettingsTests(unittest.TestCase):
    def test_private_creation_and_atomic_replacement(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td) / 'state'
            previous = os.umask(0)
            try:
                settings.write_settings(directory, '{"apiToken":"dummy"}')
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                target = directory / 'settings.json'
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                settings.write_settings(directory, '{"quickView":"today"}')
                self.assertEqual(json.loads(target.read_text()), {'quickView':'today'})
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            finally:
                os.umask(previous)

    def test_failed_replace_preserves_previous_file_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td)
            settings.write_settings(directory, '{"old":true}')
            with patch.object(settings.os, 'replace', side_effect=OSError('failure')):
                with self.assertRaises(OSError): settings.write_settings(directory, '{"new":true}')
            self.assertEqual(json.loads((directory/'settings.json').read_text()), {'old':True})
            self.assertEqual(len(list(directory.iterdir())),1)

    def test_symlink_and_invalid_json_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td)/'state'; directory.mkdir()
            target=Path(td)/'outside'; target.write_text('untouched')
            (directory/'settings.json').symlink_to(target)
            with self.assertRaises(ValueError): settings.write_settings(directory,'{}')
            self.assertEqual(target.read_text(),'untouched')
            with self.assertRaises(ValueError): settings.write_settings(directory,'[]')

if __name__ == '__main__': unittest.main()
