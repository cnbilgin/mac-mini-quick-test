# mac-mini-quick-test

A single-file, dependency-free macOS condition report for a new or used Mac — built for quickly checking a used Mac mini, but works on any Mac.

No Homebrew. No Python. No sudo. Just built-in macOS tools.

```bash
curl -fsSL https://raw.githubusercontent.com/cnbilgin/mac-mini-quick-test/master/mac-check.sh | bash
```

It prints a readable report with:

- Model, chip, RAM, serial number, hardware UUID
- Activation Lock and MDM/DEP enrollment status
- Apple warranty check link + serial
- Setup/install dates (clearly marked as reset-affected)
- SSD model, SMART status, wear, power-on hours, power cycles, data written
- Sequential write/read speed of the internal SSD
- Kernel panics, shutdown stalls, Jetsam events, install-log errors
- Recent reboot/shutdown history
- Battery cycle count/health on laptops
- Wi-Fi, Bluetooth, Thunderbolt, USB, Ethernet and display info

The report starts with a **trade-focused quick summary**, so you see the deal-breakers before scrolling:

- Find My / Activation Lock — `[OK]` or `[STOP]`
- MDM / DEP enrollment — `[OK]` or `[STOP]`
- Supervised, FileVault, SIP/Gatekeeper
- SMART, SSD wear, media errors, unsafe shutdowns, power-on hours, data written
- Kernel panics, shutdown stalls
- Battery health (laptops)
- Warranty link + serial
- A one-line verdict

Meaning of the tags:

| Tag | Meaning |
|---|---|
| `[STOP]` | Ownership blocker. Do not complete the trade until the seller removes it. |
| `[CHECK]` | Review before trading. May be a negotiation point or a repairable issue. |
| `[OK]` | That check passed. |

## One command on a fresh Mac

On a brand-new Mac mini, open **Terminal** (no Xcode, no Homebrew, no setup needed) and paste this single line:

```bash
curl -fsSL https://raw.githubusercontent.com/cnbilgin/mac-mini-quick-test/master/mac-check.sh | bash
```

That is the whole procedure. It downloads the script and runs it immediately.

- Nothing to install, nothing to `chmod`, no password prompt, no `sudo`.
- It needs an internet connection for that one `curl` (macOS ships `curl` by default).
- The full report takes roughly **1 minute** with the disk speed test, or ~10 seconds with `--no-speed`.
- If you also want a copy on disk (useful for running it again or saving the output), use the download form instead:

```bash
curl -fsSL https://raw.githubusercontent.com/cnbilgin/mac-mini-quick-test/master/mac-check.sh -o ~/mac-check.sh
chmod +x ~/mac-check.sh
~/mac-check.sh
```

Piping options is not possible in the one-liner form, so use the downloaded script when you need flags (see [Options](#options)):

```bash
~/mac-check.sh --no-speed --warranty
~/mac-check.sh --deep-logs | tee ~/mac-report.txt
```

Run it after macOS setup, from Terminal in a normal user account. It does not work from Recovery.

## Quick start from a clone

```bash
git clone https://github.com/cnbilgin/mac-mini-quick-test.git
cd mac-mini-quick-test
chmod +x mac-check.sh
./mac-check.sh
```

Save the report:

```bash
./mac-check.sh | tee mac-report.txt
```

## Options

| Option | Meaning |
|---|---|
| `--size MB` | Size of the disk speed test file. Default: `512` |
| `--runs N` | Number of speed test runs; the best result is reported. Default: `2` |
| `--no-speed` | Skip the disk speed test |
| `--deep-logs` | Also scan the unified log (slower, may take 10–30 s) |
| `--warranty` | Copy the serial to the clipboard and open Apple's coverage page |
| `--no-color` | Disable ANSI colors |
| `-h`, `--help` | Show help |

Examples:

```bash
./mac-check.sh --size 1024 --runs 3
./mac-check.sh --no-speed --warranty
./mac-check.sh --deep-logs | tee mac-report.txt
```

## What survives a macOS reset?

This matters because a used Mac is often erased before you get it.

### Wiped by a reset

- User accounts and files
- `/var/db/.AppleSetupDone` — the setup completion date
- Install history and package receipts
- `last` reboot/shutdown history (`wtmp`)
- Crash reports and panic reports in `DiagnosticReports`
- `/var/log/install.log`, `/var/log/system.log*`
- The unified log (`/usr/bin/log show`)
- The original first-boot/activation date — macOS does not store it locally after a reset

### Not wiped by a reset

- Serial number, model identifier, model number, hardware UUID
- Activation Lock status
- MDM/DEP enrollment status
- **Battery cycle count, health, maximum capacity** (laptops)
- **SSD SMART counters**: percentage used, available spare, power-on hours, power cycles, unsafe shutdowns, media errors, data written/read, temperature
- NVRAM variables such as `boot-args`, `PanicInfo`, `csr-active-config` (usually)
- Firmware password (if set — can block reinstall)

So after a reset, the **original first-boot date and old logs are gone**, but the **hardware usage history is still there**.

A Mac mini has no battery. The closest equivalent to "battery cycles" is the SSD's:

- `Power-on hours` — total hours the SSD has been powered on
- `Power cycles` — number of power cycles
- `Data written` — total terabytes written
- `Wear (percentage used)` — SSD endurance used

These are read from the SSD controller, so they survive an erase.

## What it checks

See [CHECKS.md](CHECKS.md) for a detailed explanation of every check and how to interpret it.

Highlights:

| Area | Check |
|---|---|
| Quick summary | Trade blockers and health checks at the top, with a verdict |
| Identity | Model, chip, RAM, serial, hardware UUID, provisioning UDID |
| Ownership | Activation Lock, MDM/DEP enrollment, supervision, FileVault, SIP, Gatekeeper |
| Warranty | Serial + `checkcoverage.apple.com` link |
| SSD | Model, SMART status, wear, spare, power-on hours, power cycles, unsafe shutdowns, media errors, data written/read |
| Speed | Sequential write/read using `dd` with direct I/O (cache bypassed) |
| Stability | Kernel panics, shutdown stalls, Jetsam events, install-log errors, reboot history |
| Hardware | GPU, displays, Wi-Fi, Bluetooth, Thunderbolt/USB4, USB, Ethernet, battery |

## Important limits

- **Not a substitute for Apple Diagnostics or a physical inspection.** It cannot detect all hardware faults.
- **Apple has no public warranty API.** The script prints the serial and the official coverage URL; you enter it manually.
- **The original activation/purchase date is not available locally after a reset.** Apple's coverage page and the original invoice are the authoritative sources.
- **Disk speed varies** by model, SSD capacity, FileVault, temperature and background load. Use it as a sanity check, not a benchmark score.
- **SMART values are vendor-reported.** Some Macs do not expose detailed NVMe counters; the script still shows SMART status.
- **The verdict is a guide, not a guarantee.** A clean summary does not prove the Mac is fault-free; a `[CHECK]` item does not always mean the Mac is bad.
- The script is read-only except for a temporary speed-test file under `$TMPDIR`, which is removed on exit.

## Recommended workflow for a used Mac mini

1. **Before paying**, ask the seller for the serial number and check it at <https://checkcoverage.apple.com/>.
2. Ask for the **original invoice**. After a reset, it is the best proof of purchase date.
3. Ask the seller to sign out of iCloud/Find My and remove any MDM/DEP enrollment.
4. If possible, **run this script before the reset** as well — the original setup date and old crash reports are still present then.
5. After the reset and macOS setup, run the script again. Focus on:
   - Activation Lock: **Disabled**
   - MDM: **No**
   - SMART: **Verified**
   - SSD wear, power-on hours, data written
   - Panics/stalls: ideally 0
6. Run **Apple Diagnostics**: shut down, then hold power (Apple Silicon) or `D` (Intel) at startup.
7. Test every port physically: USB, Thunderbolt, HDMI, Ethernet, audio jack.
8. Test Wi-Fi, Bluetooth, sleep/wake, and run a short CPU load to listen for fan noise.

## License

MIT — see [LICENSE](LICENSE).
