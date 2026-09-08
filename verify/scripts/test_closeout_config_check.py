import unittest
from pathlib import Path
from unittest.mock import patch

from closeout_config_check import RESOURCES, declared_settings, read_macros


class DeclaredSettingsTest(unittest.TestCase):
    def legacy(self):
        return {'RAPT_' + key: '4' for key in RESOURCES}

    def test_legacy_single_input_still_has_two_integer_ports(self):
        result = declared_settings(self.legacy())
        self.assertEqual(result['DECODE_WIDTH'], '1')
        self.assertEqual(result['COMMIT_WIDTH'], '1')
        self.assertEqual(result['INTEGER_ISSUE_PORTS'], '2')

    def test_legacy_commit_is_independent(self):
        macros = self.legacy()
        macros['RAPT_DUAL_COMMIT'] = ''
        result = declared_settings(macros)
        self.assertEqual(result['COMMIT_WIDTH'], '2')
        self.assertEqual(result['DISPATCH_WIDTH'], '1')

    def test_optional_small_headers_are_not_invented(self):
        macros = self.legacy()
        del macros['RAPT_L2_LEN']
        del macros['RAPT_CACHE_SRAMLEN']
        result = declared_settings(macros)
        self.assertIsNone(result['L2_LEN'])
        self.assertIsNone(result['CACHE_SRAMLEN'])

    def test_missing_required_resource_fails(self):
        macros = self.legacy()
        del macros['RAPT_ROB_SIZE']
        with self.assertRaises(KeyError):
            declared_settings(macros)

    def test_override_is_in_preprocessor_command(self):
        with patch('closeout_config_check.subprocess.check_output',
                   return_value='`define RAPT_INTEGER_ISSUE_PORTS 2\n'):
            macros, command = read_macros(Path('/tmp/hdl'), 64, 'small', True, 2)
        self.assertIn('-DRAPT_INTEGER_ISSUE_PORTS=2', command)
        self.assertIn('-DRAPT_RV64', command)
        self.assertIn('-DRAPT_USE_SRAM_MACRO', command)
        self.assertEqual(macros['RAPT_INTEGER_ISSUE_PORTS'], '2')

    def test_default_does_not_inject_port_override(self):
        with patch('closeout_config_check.subprocess.check_output', return_value=''):
            _, command = read_macros(Path('/tmp/hdl'), 32)
        self.assertFalse(any(arg.startswith('-DRAPT_INTEGER_ISSUE_PORTS=') for arg in command))


if __name__ == '__main__':
    unittest.main()
