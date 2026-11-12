# Battery Guard for Omarchy

A drop-in replacement for Omarchy's stock battery widget (`omarchy.power`). It keeps the stock icon, popup layout, power-profile picker and right-click percentage toggle, and adds charge-limit controls and measured battery telemetry.

## Install

```sh
omarchy plugin add https://github.com/ThePsyberSleuth/omarchy-battery-guard.git --enable
```

Or open the Omarchy menu with Super+Space, go to **Setup → Plugins → Add Plugin**, and paste the URL.

Enabling it replaces the stock battery widget in the same spot on the bar. On a machine without a battery the widget stays hidden, like the stock one.

## Remove

```sh
omarchy plugin remove thepsybersleuth.battery-guard
```

Removing or disabling it puts the stock battery widget back where it was.

## Requirements

- Omarchy 4 (Quattro) shell. Tested on Qt 6.12; palette references use `Commons.Color`, which also works on Qt 6.11.
- Everything else ships with Omarchy: UPower, `power-profiles-daemon`, Python 3.11+, polkit (`pkexec`), and the `omarchy-battery-status` and `omarchy-powerprofiles-*` commands.

## What works where

| Feature | Requirement |
| --- | --- |
| Icon, percentage, charging state, power profiles | Any battery UPower reports |
| Health, charge ratio, battery power, temperature, cycle count | Whatever your battery driver exposes in `/sys/class/power_supply`; missing values show **Unavailable** |
| Charge-limit presets (60/70/80/100%), custom limit, Top Up | The battery driver exposes `charge_control_end_threshold`, for example ThinkPad (`thinkpad_acpi`) or ASUS (`asus-wmi`), or the Framework Laptop 12 fallback below is available. Otherwise the controls stay disabled. |
| Framework Laptop 12 charge-limit controls | `framework-system` with `/usr/bin/framework_tool` and permission to read its controller; no additional kernel module required. Verified on 13th Gen Intel Core, BIOS 03.06, framework-system 0.6.6. |

## Framework Laptop 12

Install the `framework-system` package if it is not already installed. The helper recognizes Framework's Laptop 12 model and its internal `BAT1` battery. Existing sysfs charge-limit support takes priority; otherwise it uses `framework_tool --charge-limit` to query the embedded controller.

Routine status checks never open a password dialog. The helper first tries the tool directly, then the exact read-only command `sudo -n -- /usr/bin/framework_tool --charge-limit` using existing account permissions. If neither has access, the controls stay disabled with an explanation. The plugin **does not install sudo rules or change device permissions**. A read-only access check is:

```sh
sudo -n -- /usr/bin/framework_tool --charge-limit
# Minimum 0%, Maximum 100%
```

Preset buttons and custom limits use the existing polkit authorization flow. The helper preserves the controller's minimum setting, changes only the maximum, and independently queries the controller to verify the result. The supported range remains 50–100%. Polling reads the controller every 30 seconds, or every 5 seconds while the panel is open. Commands time out after 5 seconds.

The panel shows **Framework controller** under Policy. The displayed limit comes from the controller, not a cached or assumed value. Setting a limit below the current battery percentage does not imply that the battery will immediately fall to that percentage. Persistence across restart and suspend depends on the firmware and other charge-management software. Other Framework models have not been validated.

Official tool documentation: [FrameworkComputer/framework-system](https://github.com/FrameworkComputer/framework-system).

## Using it

- Left-click the battery icon to open the panel; right-click toggles the percentage next to the icon.
- The menu entry **Trigger → Toggle → Battery Percentage** and the stock **Power** keybinding reach this widget, because it answers on the stock `omarchy.power` IPC target.
- Changing the charge limit asks for your password in the system polkit dialog. The plugin installs no sudo or polkit rules, and never makes sysfs world-writable.
- The displayed limit is read back from the driver or Framework controller, not just the value you requested.
- **Top Up (100%)** keeps the limit at 100% until you choose a lower one again.

## Charge managers

- If TLP, auto-cpufreq or batctl is running, Battery Guard refuses to change the limit instead of fighting it.
- If `apple-battery-guard.service` is active, Battery Guard writes its configured limit to `/etc/apple-battery-guard/apple-battery-guard.toml` and restarts the service, so the service doesn't undo the change.
- Without a charge manager, the limit goes straight to the driver or Framework controller. Whether it survives suspend or reboot depends on the hardware.
- The Framework fallback refuses writes if any of the listed charge managers or apple-battery-guard is running.

## Limitations

- The charge controls act on the first battery that is present.
- **Sailing Mode** is shown but disabled; no start-threshold policy is implemented.
- Temperature is shown only. It does not stop charging when the battery is hot.
- Forced discharge and automatic calibration are not implemented.

## Security

Plugins run unsandboxed inside `omarchy-shell`. When you change the limit, this plugin runs `pkexec /usr/bin/python3 -I battery-control.py set <battery> <limit>` from its own folder. Polkit authorizes each change. The script writes `charge_control_end_threshold` (and the apple-battery-guard config when that service is active), or invokes `/usr/bin/framework_tool --charge-limit <limit>` on a recognized Framework Laptop 12. Arguments are passed directly without a shell, and changes are checked by reading the hardware limit back. Read `battery-control.py` before installing.

## Tests

```sh
python3 -m unittest discover -s tests -v
omarchy plugin validate .
```

The tests use temporary sysfs fixtures and mock hardware commands; they never change a real battery's settings.

## Files

- `manifest.json`: plugin id, version, and the `omarchy.power` replacement metadata.
- `GuardWidget.qml`: bar button and popup.
- `Model.js`: battery icon, status text and power-profile helpers.
- `battery-control.py`: reads sysfs telemetry and applies authenticated charge-limit changes.

## License

MIT
