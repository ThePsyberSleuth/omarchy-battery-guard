#!/usr/bin/env python3
"""Battery Guard: measured sysfs status and authenticated charge-limit changes."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

SUPPLIES = Path('/sys/class/power_supply')
ABG_CONFIG = Path('/etc/apple-battery-guard/apple-battery-guard.toml')


def text(path):
    try:
        return path.read_text().strip()
    except (OSError, UnicodeError):
        return None


def number(path):
    try:
        return float(text(path))
    except (TypeError, ValueError):
        return None


def batteries():
    return sorted(p for p in SUPPLIES.iterdir()
                  if text(p / 'type') == 'Battery' and text(p / 'present') != '0'
                  and text(p / 'scope') != 'Device')


def active(unit):
    return subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def metrics(bat):
    def n(key):
        return number(bat / key)
    now, full, design = n('charge_now'), n('charge_full'), n('charge_full_design')
    if full is None:
        now, full, design = n('energy_now'), n('energy_full'), n('energy_full_design')
    watts = n('power_now')
    if watts is not None:
        watts = abs(watts) / 1e6
    elif n('current_now') is not None and n('voltage_now') is not None:
        watts = abs(n('current_now') * n('voltage_now')) / 1e12
    temperature = n('temp')
    end = n('charge_control_end_threshold')
    start = n('charge_control_start_threshold')
    return dict(name=bat.name, model=text(bat / 'model_name'),
                capacity=n('capacity'), status=text(bat / 'status') or 'Unknown',
                charge_ratio=round(now / full * 100, 1) if now is not None and full else None,
                health=round(full / design * 100, 1) if full is not None and design else None,
                watts=round(watts, 2) if watts is not None else None,
                temperature=temperature / 10 if temperature is not None else None,
                cycles=n('cycle_count'), end=end, start=start,
                can_limit=end is not None, can_start=start is not None,
                behaviour=text(bat / 'charge_behaviour'))


def status():
    manager = 'apple-battery-guard' if active('apple-battery-guard.service') else None
    configured = None
    error = None
    if manager:
        try:
            configured = tomllib.loads(ABG_CONFIG.read_text())['battery']['charge_end_threshold']
        except (OSError, ValueError, KeyError) as exc:
            error = str(exc)
    return dict(ok=True, batteries=[metrics(b) for b in batteries()],
                ac_online=any(text(p / 'online') == '1' for p in SUPPLIES.iterdir()
                              if text(p / 'type') in ('Mains', 'USB', 'USB_C', 'USB_PD')),
                manager=manager, configured_limit=configured, manager_error=error)


def replace_abg_limit(source, limit):
    parsed = tomllib.loads(source)
    if 'charge_end_threshold' not in parsed.get('battery', {}):
        raise ValueError('Charge manager configuration has no battery charge_end_threshold')
    section = None
    result = []
    count = 0
    for line in source.splitlines(keepends=True):
        if line.strip().startswith('['):
            section = line.strip().split('#', 1)[0].strip()
        if section == '[battery]' and re.match(r'^\s*charge_end_threshold\s*=', line):
            result.append(f'charge_end_threshold = {limit}\n')
            count += 1
        else:
            result.append(line)
    if count != 1:
        raise ValueError('Ambiguous charge manager configuration')
    changed = ''.join(result)
    tomllib.loads(changed)
    return changed


def apply(name, limit):
    if not 50 <= limit <= 100:
        raise ValueError('Choose a charge limit from 50 to 100 percent')
    selected = next((b for b in batteries() if b.name == name), None)
    if selected is None:
        raise ValueError('Selected battery is not present')
    threshold = selected / 'charge_control_end_threshold'
    if not threshold.exists():
        raise ValueError('This battery driver does not expose a charge limit')
    conflicts = [unit for unit in ('tlp.service', 'auto-cpufreq.service', 'batctl.service') if active(unit)]
    if conflicts:
        raise ValueError('Another charge manager may overwrite limits: ' + ', '.join(conflicts))
    old_limit = text(threshold)
    if active('apple-battery-guard.service'):
        if selected != batteries()[0]:
            raise ValueError('apple-battery-guard only manages the first battery')
        original = ABG_CONFIG.read_text()
        if tomllib.loads(original).get('full_charge', {}).get('enabled', False):
            raise ValueError('Disable the scheduled full-charge day in apple-battery-guard before changing limits here')
        changed = replace_abg_limit(original, limit)
        try:
            # Check kernel acceptance before updating persistent policy.
            threshold.write_text(str(limit) + '\n')
            if number(threshold) != limit:
                raise ValueError('Driver did not accept the requested limit')
            ABG_CONFIG.write_text(changed)
            subprocess.run(['/usr/bin/systemctl', 'restart', 'apple-battery-guard.service'], check=True)
        except Exception:
            ABG_CONFIG.write_text(original)
            if old_limit is not None:
                threshold.write_text(old_limit + '\n')
            subprocess.run(['/usr/bin/systemctl', 'restart', 'apple-battery-guard.service'], check=False)
            raise
        persistence = 'Saved in apple-battery-guard; reapplied by its service'
    else:
        start = number(selected / 'charge_control_start_threshold')
        if start is not None and start >= limit:
            raise ValueError(f'The start threshold ({start:g}%) must be lower than the new limit')
        threshold.write_text(str(limit) + '\n')
        persistence = 'Applied to driver; boot/resume persistence depends on hardware'
    actual = number(threshold)
    if actual != limit:
        raise ValueError(f'Driver reports {actual}, not requested limit {limit}')
    return dict(ok=True, message=f'Charge limit set to {limit}%. {persistence}.', limit=actual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('status')
    setting = commands.add_parser('set')
    setting.add_argument('battery')
    setting.add_argument('limit', type=int, choices=range(50, 101), metavar='50..100')
    args = parser.parse_args()
    try:
        if args.command == 'status':
            result = status()
        elif os.geteuid() == 0:
            result = apply(args.battery, args.limit)
        else:
            # Authenticate the exact operation; never make sysfs world-writable.
            proc = subprocess.run(['/usr/bin/pkexec', '/usr/bin/python3', '-I',
                                   str(Path(__file__).resolve()), 'set', args.battery, str(args.limit)],
                                  capture_output=True, text=True)
            if proc.returncode:
                try:
                    error = json.loads(proc.stdout).get('error')
                except (ValueError, TypeError):
                    error = None
                raise ValueError(error or proc.stderr.strip() or 'Authorization cancelled or denied')
            result = json.loads(proc.stdout)
        print(json.dumps(result))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps(dict(ok=False, error=str(exc))))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
