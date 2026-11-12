import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('battery_control', Path(__file__).parents[1] / 'battery-control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class BatteryControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for constant, directory in [('SUPPLIES', 'supplies'), ('DMI', 'dmi')]:
            folder = self.root / directory
            folder.mkdir()
            self.start_patch(constant, folder)
        for constant in ('FRAMEWORK_TOOL', 'SUDO'):
            executable = self.root / constant.lower()
            executable.touch()
            self.start_patch(constant, executable)
        self.start_patch('ABG_CONFIG', self.root / 'abg.toml')
        self.start_patch('active', return_value=False)
        self.uid = self.start_patch('os.geteuid', return_value=0)
        self.run = self.start_patch('subprocess.run')
        (control.DMI / 'sys_vendor').write_text('Framework\n')
        (control.DMI / 'product_name').write_text('Laptop 12 (13th Gen Intel Core)\n')
        self.bat = self.battery('BAT1')

    def start_patch(self, name, *args, **kwargs):
        if '.' in name:
            owner, attr = name.split('.')
            context = patch.object(getattr(control, owner), attr, *args, **kwargs)
        else:
            context = patch.object(control, name, *args, **kwargs)
        value = context.start()
        self.addCleanup(context.stop)
        return value

    def battery(self, name, **attributes):
        battery = control.SUPPLIES / name
        battery.mkdir()
        for name, value in {'type': 'Battery', 'present': '1', 'capacity': '100', **attributes}.items():
            (battery / name).write_text(str(value) + '\n')
        return battery

    @staticmethod
    def reply(maximum=100, minimum=0, code=0, stderr=''):
        return subprocess.CompletedProcess([], code, f'Minimum {minimum}%, Maximum {maximum}%\n', stderr)

    def test_detects_exact_laptop12(self):
        self.assertTrue(control.framework_supported(self.bat))

    def test_rejects_other_models_and_vendors(self):
        for model in ('Laptop 13 (13th Gen Intel Core)', 'Laptop 16', 'Laptop 120', 'Laptop 12 Pro'):
            with self.subTest(model=model):
                (control.DMI / 'product_name').write_text(model)
                self.assertFalse(control.framework_supported(self.bat))
        (control.DMI / 'product_name').write_text('Laptop 12')
        (control.DMI / 'sys_vendor').write_text('Other')
        self.assertFalse(control.framework_supported(self.bat))

    def test_requires_internal_battery_and_installed_tool(self):
        self.assertFalse(control.framework_supported(self.battery('BAT2')))
        control.FRAMEWORK_TOOL.unlink()
        self.assertFalse(control.framework_supported(self.bat))

    def test_parse_controller_limits(self):
        self.assertEqual(control.parse_framework_limits('Minimum 0%, Maximum 70%\n'), (0, 70))

    def test_rejects_malformed_error_and_out_of_range_output(self):
        for output in ('', '[ERROR] No EC', 'Maximum 70%', 'Minimum 80%, Maximum 70%',
                       'Minimum 0%, Maximum 101%', 'Minimum -1%, Maximum 70%',
                       '<img src="https://example.invalid">', 'Minimum 0%, Maximum 70%\n[ERROR] failed'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                control.parse_framework_limits(output)

    def test_root_read_uses_framework_directly(self):
        self.run.return_value = self.reply(70)
        self.assertEqual(control.framework_limits(), (0, 70))
        self.assertEqual(self.run.call_args.args[0], [str(control.FRAMEWORK_TOOL), '--charge-limit'])
        self.assertEqual(self.run.call_args.kwargs['timeout'], 5)

    def test_unprivileged_read_works_without_sudo_when_permitted(self):
        self.uid.return_value = 1000
        self.run.return_value = self.reply(70)
        self.assertEqual(control.framework_limits(), (0, 70))
        self.assertEqual(self.run.call_count, 1)

    def test_read_falls_back_to_noninteractive_sudo(self):
        self.uid.return_value = 1000
        self.run.side_effect = [subprocess.CompletedProcess([], 0, '[ERROR] Permission denied', ''), self.reply(70)]
        self.assertEqual(control.framework_limits(), (0, 70))
        self.assertEqual(self.run.call_args.args[0],
                         [str(control.SUDO), '-n', '--', str(control.FRAMEWORK_TOOL), '--charge-limit'])

    def test_permission_failure_disables_controls_with_actionable_error(self):
        self.uid.return_value = 1000
        self.run.return_value = subprocess.CompletedProcess([], 1, '', 'sudo: a password is required')
        status = control.status()
        self.assertTrue(status['ok'])
        battery = status['batteries'][0]
        self.assertFalse(battery['can_limit'])
        self.assertIsNone(battery['end'])
        self.assertIn('passwordless sudo', battery['backend_error'])
        self.assertEqual(self.run.call_count, 2)

    def test_missing_sudo_reports_failure_without_prompt(self):
        self.uid.return_value = 1000
        control.SUDO.unlink()
        self.run.return_value = subprocess.CompletedProcess([], 1, '', 'permission denied')
        with self.assertRaisesRegex(ValueError, 'permission denied'):
            control.framework_limits()
        self.assertEqual(self.run.call_count, 1)

    def test_timeout_preserves_telemetry_and_reports_backend_error(self):
        self.run.side_effect = subprocess.TimeoutExpired('framework_tool', 5)
        status = control.metrics(self.bat)
        self.assertEqual(status['capacity'], 100)
        self.assertFalse(status['can_limit'])
        self.assertIn('timed out', status['backend_error'])

    def test_live_status_reports_framework_limit_without_start_policy(self):
        self.run.return_value = self.reply(70)
        battery = control.status()['batteries'][0]
        self.assertEqual(battery['backend'], 'framework-tool')
        self.assertEqual(battery['end'], 70)
        self.assertTrue(battery['can_limit'])
        self.assertFalse(battery['can_start'])
        self.assertIsNone(battery['backend_error'])

    def test_sysfs_is_preferred_even_on_framework(self):
        (self.bat / 'charge_control_end_threshold').write_text('80\n')
        battery = control.metrics(self.bat)
        self.assertEqual(battery['backend'], 'sysfs')
        self.assertEqual(battery['end'], 80)
        self.run.assert_not_called()

    def test_malformed_sysfs_is_not_overridden(self):
        (self.bat / 'charge_control_end_threshold').write_text('bad')
        self.assertFalse(control.metrics(self.bat)['can_limit'])
        self.run.assert_not_called()

    def test_unsupported_system_is_unchanged(self):
        (control.DMI / 'product_name').write_text('Laptop 13')
        self.assertFalse(control.metrics(self.bat)['can_limit'])
        with self.assertRaisesRegex(ValueError, 'does not expose'):
            control.apply('BAT1', 70)
        self.run.assert_not_called()

    def test_framework_write_and_independent_readback(self):
        self.run.side_effect = [self.reply(100), self.reply(70), self.reply(70)]
        result = control.apply('BAT1', 70)
        self.assertTrue(result['ok'])
        self.assertEqual(result['limit'], 70)
        self.assertEqual([call.args[0] for call in self.run.call_args_list], [
            [str(control.FRAMEWORK_TOOL), '--charge-limit'],
            [str(control.FRAMEWORK_TOOL), '--charge-limit', '70'],
            [str(control.FRAMEWORK_TOOL), '--charge-limit'],
        ])

    def test_readback_mismatch_is_never_reported_as_success(self):
        self.run.side_effect = [self.reply(100), self.reply(70), self.reply(100)]
        with self.assertRaisesRegex(ValueError, 'reports 100, not requested limit 70'):
            control.apply('BAT1', 70)

    def test_setter_error_with_zero_exit_is_detected(self):
        self.run.side_effect = [self.reply(100), subprocess.CompletedProcess([], 0, '[ERROR] Unsupported command', '')]
        with self.assertRaisesRegex(ValueError, 'did not report valid'):
            control.apply('BAT1', 70)

    def test_conflicting_manager_blocks_framework_write(self):
        for manager in ('tlp.service', 'auto-cpufreq.service', 'batctl.service'):
            with self.subTest(manager=manager), patch.object(control, 'active', side_effect=lambda unit: unit == manager):
                with self.assertRaisesRegex(ValueError, 'Another charge manager'):
                    control.apply('BAT1', 70)
        self.run.assert_not_called()

    def test_apple_manager_requires_native_threshold(self):
        with patch.object(control, 'active', side_effect=lambda unit: unit == 'apple-battery-guard.service'):
            with self.assertRaisesRegex(ValueError, 'requires a sysfs'):
                control.apply('BAT1', 70)
        self.run.assert_not_called()

    def test_framework_minimum_is_preserved(self):
        self.run.return_value = self.reply(100, minimum=80)
        with self.assertRaisesRegex(ValueError, r'minimum \(80%\)'):
            control.apply('BAT1', 70)
        self.assertEqual(self.run.call_count, 1)

    def test_invalid_limits_and_unknown_battery_are_rejected(self):
        for limit in (0, 49, 101):
            with self.subTest(limit=limit), self.assertRaisesRegex(ValueError, '50 to 100'):
                control.apply('BAT1', limit)
        for name in ('missing', '../BAT1', 'BAT1; touch /tmp/unsafe'):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'not present'):
                control.apply(name, 70)
        self.run.assert_not_called()

    def test_native_sysfs_write_still_works(self):
        threshold = self.bat / 'charge_control_end_threshold'
        threshold.write_text('80\n')
        self.assertEqual(control.apply('BAT1', 70)['limit'], 70)
        self.assertEqual(threshold.read_text(), '70\n')
        self.run.assert_not_called()

    def test_native_start_threshold_guard_is_preserved(self):
        threshold = self.bat / 'charge_control_end_threshold'
        threshold.write_text('100\n')
        (self.bat / 'charge_control_start_threshold').write_text('80\n')
        with self.assertRaisesRegex(ValueError, 'start threshold'):
            control.apply('BAT1', 70)
        self.assertEqual(threshold.read_text(), '100\n')

    def test_peripheral_batteries_are_excluded(self):
        self.battery('peripheral', scope='Device')
        self.assertEqual(control.batteries(), [self.bat])

    def test_native_apple_manager_updates_configuration(self):
        threshold = self.bat / 'charge_control_end_threshold'
        threshold.write_text('100\n')
        control.ABG_CONFIG.write_text('[battery]\ncharge_end_threshold = 100\n[full_charge]\nenabled = false\n')
        with patch.object(control, 'active', side_effect=lambda unit: unit == 'apple-battery-guard.service'):
            self.assertEqual(control.apply('BAT1', 70)['limit'], 70)
        self.assertIn('charge_end_threshold = 70', control.ABG_CONFIG.read_text())

    def test_unprivileged_write_still_requires_polkit(self):
        self.uid.return_value = 1000
        self.run.return_value = subprocess.CompletedProcess([], 0, '{"ok": true, "limit": 70}', '')
        output = io.StringIO()
        with patch.object(control.sys, 'argv', ['battery-control.py', 'set', 'BAT1', '70']), patch('sys.stdout', output):
            self.assertEqual(control.main(), 0)
        command = self.run.call_args.args[0]
        self.assertEqual(command[:4], ['/usr/bin/pkexec', '/usr/bin/python3', '-I',
                                     str(Path(control.__file__).resolve())])
        self.assertEqual(command[4:], ['set', 'BAT1', '70'])
        self.assertTrue(json.loads(output.getvalue())['ok'])

    def test_authorization_rejection_returns_error(self):
        self.uid.return_value = 1000
        self.run.return_value = subprocess.CompletedProcess([], 126, '', 'Authorization cancelled')
        output = io.StringIO()
        with patch.object(control.sys, 'argv', ['battery-control.py', 'set', 'BAT1', '70']), patch('sys.stdout', output):
            self.assertEqual(control.main(), 1)
        self.assertFalse(json.loads(output.getvalue())['ok'])
        self.assertIn('Authorization cancelled', json.loads(output.getvalue())['error'])


if __name__ == '__main__':
    unittest.main()
