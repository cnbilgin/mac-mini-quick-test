# What the report checks

This document explains every section of `mac-check.sh`, how to interpret the values, and whether the data survives a macOS reset.

## Reset survival

| Data | Survives reset? | Where it lives |
|---|---|---|
| Serial number, model, model number, hardware UUID | Yes | Firmware |
| Activation Lock status | Yes | Apple server + firmware |
| MDM/DEP enrollment | Yes | Apple server |
| Battery cycle count, health, max capacity | Yes | Battery controller |
| SSD wear, power-on hours, power cycles, data written, unsafe shutdowns, media errors | Yes | SSD controller |
| NVRAM (`boot-args`, `PanicInfo`, `csr-active-config`) | Usually | NVRAM |
| Firmware password | Yes | Firmware |
| Setup Assistant date (`.AppleSetupDone`) | No | macOS data volume |
| Install history and package receipts | No | macOS data volume |
| Reboot/shutdown history (`wtmp`) | No | macOS data volume |
| Crash/panic/shutdown-stall reports | No | macOS data volume |
| Unified log | No | macOS data volume |
| Original first-boot/activation date | No local record | Apple coverage / invoice |

A reset wipes the macOS data volume. It does **not** wipe the hardware counters. That is why the script uses the SSD and battery counters for lifetime usage, and the serial number for warranty/age.

## Quick summary / verdict

The first section of the report is the trade-focused summary. It is printed before the detailed sections so the deal-breakers are visible immediately.

| Tag | Meaning |
|---|---|
| `[STOP]` | Ownership blocker. Do not complete the trade until it is resolved. |
| `[CHECK]` | Review before trading. May be a negotiation point or a repairable issue. |
| `[OK]` | That check passed. |

### `[STOP]` conditions

- Find My / Activation Lock is **Enabled** or **Unknown**
- MDM/DEP enrollment is not confirmed clean
- Firmware password is **Enabled** (checked with `--sudo`)

The verdict is `STOP` if any of these is present.

### `[CHECK]` conditions

- This Mac is supervised
- FileVault is On
- SIP is disabled or customized
- Gatekeeper is disabled
- SMART status is not `Verified`
- SSD wear is ≥ 50%
- SSD media errors > 0
- SSD unsafe shutdowns > 0
- Kernel panics > 0
- Shutdown stalls > 0
- Install log contains errors
- Battery health is Service/Replace/Poor
- Configuration profiles were found (`--sudo`)
- Firmware password/profiles check was requested but skipped (`--sudo` without a terminal)

The verdict is `CHECK` if any of these is present and there is no `[STOP]`.

Otherwise the verdict is `OK`.

The disk speed test and `--deep-logs` scan run after the quick summary, so warnings from those appear only in the final **Warnings** section. The summary's warning count is taken before those two checks.

Use `--brief` to print only the quick summary and the warnings.

## 1. Identity

| Field | Meaning |
|---|---|
| Model / model identifier | Marketing name and board identifier, e.g. `Mac mini (Mac16,10)` |
| Model number | Region-specific part number |
| Chip | Apple Silicon chip or Intel CPU |
| CPU | Total cores and P/E split on Apple Silicon |
| Memory | Installed RAM |
| Serial number | Use this for Apple warranty/coverage lookup |
| Hardware UUID | Unique hardware identifier |
| Provisioning UDID | Apple Silicon device identifier |
| macOS / kernel | OS version, build and Darwin kernel |
| Boot mode | Normal boot vs. recovery/safe mode |
| Last boot / uptime | Current boot time, not first boot |
| Activation Lock | **Disabled** is what you want. **Enabled** means the Mac is iCloud-locked. |

### Activation Lock

- `Disabled` — the previous owner signed out of iCloud/Find My, or the Mac was never locked.
- `Enabled` — do not buy/keep until the seller removes it. It cannot be bypassed safely.
- `Unknown` — check manually in System Settings > General > Device Management / Apple Account.

## 2. Setup / install dates (reset-aware)

| Field | Meaning |
|---|---|
| Setup Assistant done | Creation time of `/var/db/.AppleSetupDone` — when the current macOS install was set up |
| First macOS install | Earliest entry in `system_profiler SPInstallHistoryDataType` on the current volume |
| Oldest package receipt | Oldest file in `/var/db/receipts` |
| Reboot log begins | Start of `wtmp` history |

If the Mac was reset, all four dates show the reset/reinstall date, not the original first boot. macOS does not keep the original activation date locally after an erase. Use the serial + Apple coverage page and the original invoice for that.

If the install is only a few days old, the script prints a warning that it is likely a fresh reset.

## 3. Security / ownership / warranty

| Check | Good value | Notes |
|---|---|---|
| Enrolled via DEP | No | Yes means an organization claimed it |
| MDM enrollment | No | Yes means it can be remotely managed/locked |
| FileVault | Off or On | Off is normal for a desktop; On is fine |
| SIP | enabled | Disabled may indicate tampering |
| Gatekeeper | assessments enabled | Disabled may indicate tampering |
| Supervised | false | true means it was managed by an organization |
| Firmware password (`--sudo`) | No / Disabled | Yes means the seller must remove it before the trade |
| Configuration profiles (`--sudo`) | None | Any profile should be reviewed |

`--sudo` runs two extra read-only checks: `sudo firmwarepasswd -check` and `sudo profiles -P`. It does not change anything. On Apple Silicon, `firmwarepasswd` may report that the tool is not supported; that is normal. If `--sudo` is requested without an interactive terminal, the checks are skipped and the report shows that.

### Warranty

Apple has no public warranty API. The script prints:

- `https://checkcoverage.apple.com/`
- The serial number to enter

The coverage page can show the estimated purchase date and coverage end date. For a used Mac, also ask for the original invoice.

`--warranty` copies the serial to the clipboard and opens the page.

## 4. SSD health

The script reads the physical NVMe disk via `diskutil info -plist` and extracts the NVMe SMART/Health log. These values come from the SSD controller and survive a reset.

| Field | Meaning | Good range |
|---|---|---|
| Disk / capacity / bus | Model, size, connection | — |
| Internal / Media | Internal SSD vs. external/HDD | Internal + SSD |
| SMART status | Overall SMART verdict | `Verified` |
| Wear (percentage used) | Vendor wear indicator | 0–10% excellent; 10–50% normal; 50–80% aging; >80% high |
| Available spare | Spare blocks for wear leveling | Above the threshold (usually 99–100%) |
| Power-on hours | Total hours the SSD has been powered | Lower is newer; compare with cycles and data written |
| Power cycles | Number of power cycles | Lower is newer |
| Unsafe shutdowns | Power loss / forced power-off count | A few is normal; many may indicate power issues |
| Media errors | Uncorrectable media errors | 0 |
| Data written | Total terabytes written | Compare with SSD endurance; lower is better |
| Data read | Total terabytes read | Informational |
| Temperature | SSD temperature | Roughly 20–50 °C idle |

### Mac mini: no battery

A Mac mini has no battery, so there is no cycle count. The SSD `Power-on hours`, `Power cycles` and `Data written` are the closest equivalent to battery cycles. They persist across erases.

### Unsafe shutdowns

`Unsafe shutdowns` is a cumulative NVMe SMART counter. It increments when the SSD loses power without a clean shutdown/flush, for example:

- holding the power button
- power loss or unplugging
- a kernel panic or forced restart
- a shutdown stall that ends in a forced power-off

It is **not** a wear indicator like `Percentage Used`. Compare it to `Power cycles` and `Power-on hours`:

- A low ratio is usually historical and not alarming. Example: 6 / 274 power cycles = ~2.2%.
- A high ratio, or a counter that keeps increasing, suggests repeated power loss or forced shutdowns.

What to check:

1. `Media errors` should be 0 and `SMART status` should be `Verified`.
2. `Kernel panics` and `Shutdown stalls` should not be increasing.
3. Power source should be stable: battery/charger on a laptop, cable/UPS on a Mac mini.
4. If the counter keeps rising without forced power-offs, run Apple Diagnostics and inspect shutdown-stall reports.

### Free space

The script warns if the boot volume has less than 10% free. APFS performance and updates need headroom.

### Speed test

The script writes a temporary file under `$TMPDIR` using `dd` with `oflag=direct`, then reads it with `iflag=direct`. Direct I/O bypasses the file cache, so the result reflects the SSD more closely than a normal `dd` run.

- Default: 512 MiB blocks, 2 runs, best result.
- The test file is removed on exit.
- If direct I/O is unsupported, it retries without it and prints a note.
- Speeds vary by model, capacity, FileVault, temperature and background load. Use it as a sanity check.

Typical rough ranges:

- Apple Silicon internal SSD: thousands of MB/s
- Intel SATA SSD Mac mini: around 500 MB/s
- A dramatically lower result than expected is worth investigating

## 5. Stability / crash history

| Check | What it means |
|---|---|
| Last boot / uptime | Current boot only |
| Recent reboots/shutdowns | From `last reboot` (`wtmp`); wiped by reset |
| Kernel panics | `.panic` files and `.ips` reports with `bug_type 210` / `panicString` |
| Shutdown stalls | `.shutdownStall` reports; macOS detected a slow/stuck shutdown |
| Jetsam events | Memory-pressure kills; usually software, not hardware |
| Other `.ips` / `.diag` | App/system crash reports |
| Install log errors | Counts `install failed`, `I/O error`, `disk error` in `/var/log/install.log` |
| Deep logs (`--deep-logs`) | Last hour of kernel errors, I/O errors and previous shutdown cause |

After a reset, these only cover the new install. A clean reset often has zero reports. A non-zero panic/stall count on a fresh install is more concerning than on an old install.

### Shutdown stalls

A `.shutdownStall` report means macOS detected a slow or stuck shutdown. It is often software (an app or background service not quitting), not a failing SSD. A short 1-second stall with many background apps is usually benign.

Inspect it with:

```bash
ls -lt /Library/Logs/DiagnosticReports/*.shutdownStall
spindump -i /Library/Logs/DiagnosticReports/<file>.shutdownStall
# readable report: /tmp/spindump.txt
```

Look at the `Event`, `Duration`, and the processes sampled. If stalls repeat, note which apps are open, try Safe Mode, and check login items/background agents.

## 6. NVRAM / boot flags

| Field | Good value | Notes |
|---|---|---|
| `boot-args` | none | Unusual flags (`-v`, `debug`, `keepsyms`, `amfi_get_out_of_my_way`, `-s`) can indicate debugging/tampering |
| `PanicInfo` | none | A previous panic was recorded (mostly Intel Macs) |
| `csr-active-config` | not set / 0 | Non-zero means SIP may have been customized |
| `supervised` | false | true means organization supervision |

NVRAM usually survives a reset, but some reset flows clear it. Treat it as a hint, not proof.

## 7. Hardware / ports

| Check | What to look for |
|---|---|
| GPU / Metal | Expected chip and Metal support |
| Displays | At least one display detected; resolution looks sane |
| Wi-Fi | On, link active, expected PHY modes |
| Bluetooth | On, chipset present |
| Hardware ports | Ethernet, Thunderbolt, USB and other ports listed |
| Thunderbolt/USB4 | Bus count, connected devices, link speed |
| USB | Connected devices and hubs |
| Battery (laptop) | Cycle count, health, max capacity |

These are inventory checks, not full hardware tests. Physically test every port.

## 8. Manual checks

The script cannot test these automatically:

- Apple Diagnostics (hold power on Apple Silicon, `D` on Intel)
- Firmware password: `--sudo` (or `sudo firmwarepasswd -check`)
- Installed profiles: `--sudo` (or `sudo profiles -P`)
- Detailed SMART: `sudo smartctl -a /dev/disk0` (only if smartmontools is installed)
- Every USB/Thunderbolt/HDMI/Ethernet/audio port
- Fan noise and thermal throttling under load
- Sleep/wake behavior
- Wi-Fi/Bluetooth with real devices
- Speakers/microphone
- Original invoice and seller confirmation that Activation Lock/MDM are removed

## Warnings used by the script

The script adds a warning for:

- Activation Lock enabled or unknown
- MDM/DEP enrollment active
- Firmware password enabled
- Configuration profiles found
- `--sudo` check requested but skipped
- Supervised = true
- FileVault is On
- SIP disabled or customized
- Gatekeeper disabled
- SMART status not `Verified`
- SSD wear ≥ 50%
- SSD media errors > 0
- Unsafe shutdowns > 0 (the warning includes the ratio to power cycles)
- Available spare below threshold
- Free space < 10%
- Disk speed test failed
- Kernel panics > 0
- Shutdown stalls > 0
- User kernel panics > 0
- Install log errors > 0
- `PanicInfo` present in NVRAM
- Unusual `boot-args`
- Non-zero `csr-active-config`
- Battery health reported as Service/Replace/Poor
- I/O errors in the unified log (only with `--deep-logs`)

The report is a guide, not a verdict. A clean report does not guarantee a fault-free Mac, and a warning does not always mean the Mac is bad.

## Commands used

For transparency, the main built-in commands are:

```text
system_profiler SPHardwareDataType SPSoftwareDataType -json
system_profiler SPNVMeDataType -json
system_profiler SPInstallHistoryDataType -json
system_profiler SPDisplaysDataType SPAirPortDataType SPBluetoothDataType
system_profiler SPThunderboltDataType SPUSBDataType SPPowerDataType
diskutil info -plist disk0
diskutil list -plist
plutil -extract ...
stat -f %B /var/db/.AppleSetupDone
find /var/db/receipts ...
last reboot
profiles status -type enrollment
fdesetup status
csrutil status
spctl --status
nvram -p
df -k
dd if=/dev/zero of=... bs=1m count=... oflag=direct
/usr/bin/log show ...            # only with --deep-logs
sudo firmwarepasswd -check       # only with --sudo
sudo profiles -P                 # only with --sudo
spindump -i ...                  # to decode a shutdown stall report
```

No third-party tools, no Python. `sudo` is optional and only used with `--sudo`.
