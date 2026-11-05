#!/bin/bash
#
# mac-check.sh — quick condition report for a new or used Mac
#
# No Homebrew, Python, or sudo required. Uses built-in macOS tools only.
# Designed for macOS 12+ (Apple Silicon and Intel).
#
# Usage:
#   ./mac-check.sh [options]
#
# Options:
#   --size MB       Size of the disk speed test file (default: 512)
#   --runs N        Number of disk speed test runs (default: 2)
#   --no-speed      Skip the disk speed test
#   --deep-logs     Also scan the unified log (slower, may take 10-30s)
#   --warranty      Open Apple's warranty page and copy the serial
#   --no-color      Disable ANSI colors
#   -h, --help      Show this help
#
# License: MIT

set -u

# Force English command output so parsing is stable.
export LC_ALL=C
export LANG=C

VERSION="1.0.0"

SIZE_MB=512
RUNS=2
DO_SPEED=1
DEEP_LOGS=0
OPEN_WARRANTY=0
BRIEF=0
SUDO_MODE=0
TEST_DIR=""
WARNINGS=""
WARNING_COUNT=0
VERDICT_LEVEL="ok"
VERDICT_TEXT=""
FW_PASS_TEXT=""
FW_PASS_ENABLED=0
PROFILES_TEXT=""
SUDO_SKIPPED=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  NC=$'\033[0m'
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

usage() {
  cat <<'EOF'
mac-check.sh — quick condition report for a new or used Mac

No Homebrew, Python, or sudo required. Uses built-in macOS tools only.

Usage:
  ./mac-check.sh [options]

Options:
  --size MB       Size of the disk speed test file (default: 512)
  --runs N        Number of disk speed test runs (default: 2)
  --no-speed      Skip the disk speed test
  --deep-logs     Also scan the unified log (slower, may take 10-30s)
  --warranty      Open Apple's warranty page and copy the serial
  --brief         Show only the quick summary and warnings
  --sudo          Also check firmware password and installed profiles (prompts)
  --no-color      Disable ANSI colors
  -h, --help      Show this help

Notes:
  - Run this from Terminal in a normal user account, after macOS setup.
  - The disk speed test writes a temporary file under $TMPDIR and removes it.
  - This report cannot replace Apple Diagnostics or a physical inspection.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

section() {
  printf '\n%s== %s ==%s\n' "$BLUE$BOLD" "$1" "$NC"
}

kv() {
  printf '  %-28s %s\n' "$1" "$2"
}

note() {
  printf '  %s%s%s\n' "$DIM" "$1" "$NC"
}

ok_line() {
  printf '  %s%s%s\n' "$GREEN" "$1" "$NC"
}

warn_line() {
  printf '  %s%s%s\n' "$YELLOW" "$1" "$NC"
}

bad_line() {
  printf '  %s%s%s\n' "$RED" "$1" "$NC"
}

status_line() {
  # $1 = label, $2 = value, $3 = ok|warn|bad
  case "$3" in
    ok)   printf '  %-28s %s[OK]%s %s\n' "$1" "$GREEN" "$NC" "$2" ;;
    warn) printf '  %-28s %s[CHECK]%s %s\n' "$1" "$YELLOW" "$NC" "$2" ;;
    bad)  printf '  %-28s %s[STOP]%s %s\n' "$1" "$RED" "$NC" "$2" ;;
    *)    printf '  %-28s %s\n' "$1" "$2" ;;
  esac
}

add_warning() {
  WARNINGS="${WARNINGS}- $1"$'\n'
}

plist_get() {
  # $1 = plist/JSON text, $2 = key path
  local out
  out=$(printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null)
  case "$out" in
    *"Could not extract value"*|*"invalid key path"*|*"Unexpected character"*) printf '' ;;
    *) printf '%s' "$out" ;;
  esac
}

format_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1e12) printf "%.2f TB", b/1e12;
    else if (b >= 1e9) printf "%.1f GB", b/1e9;
    else if (b >= 1e6) printf "%.0f MB", b/1e6;
    else printf "%.0f bytes", b;
  }'
}

format_data_units() {
  # NVMe data units are reported in thousands of 512-byte units.
  awk -v u="${1:-0}" 'BEGIN { printf "%.2f TB", u * 512000 / 1e12 }'
}

format_speed() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1e9) printf "%.0f MB/s (%.2f GB/s)", b/1e6, b/1e9;
    else printf "%.0f MB/s", b/1e6;
  }'
}

format_duration() {
  awk -v s="${1:-0}" 'BEGIN {
    d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if (d>0) printf "%dd %dh %dm", d, h, m;
    else if (h>0) printf "%dh %dm", h, m;
    else printf "%dm", m;
  }'
}

human_date() {
  if [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null; then
    date -r "$1" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
}

iso_to_local() {
  # $1 = ISO 8601 UTC, e.g. 2024-01-12T23:17:52Z
  local iso="$1" out
  [ -z "$iso" ] && { printf 'unknown'; return; }
  out=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$iso"; fi
}

cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --size)
      shift; [ $# -gt 0 ] || die "--size needs a value"
      SIZE_MB="$1"
      ;;
    --runs)
      shift; [ $# -gt 0 ] || die "--runs needs a value"
      RUNS="$1"
      ;;
    --no-speed) DO_SPEED=0 ;;
    --deep-logs) DEEP_LOGS=1 ;;
    --warranty) OPEN_WARRANTY=1 ;;
    --brief) BRIEF=1 ;;
    --sudo) SUDO_MODE=1 ;;
    --no-color)
      BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$SIZE_MB" in ''|*[!0-9]*) die "--size must be a number in MB" ;; esac
case "$RUNS" in ''|*[!0-9]*) die "--runs must be a number" ;; esac
[ "$SIZE_MB" -ge 64 ] || die "--size must be at least 64 MB"
[ "$RUNS" -ge 1 ] || die "--runs must be at least 1"

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------
collect_identity() {
  SYS_JSON=$(system_profiler SPHardwareDataType SPSoftwareDataType -json 2>/dev/null)

  MODEL_NAME=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.machine_name")
  MODEL_ID=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.machine_model")
  [ -z "$MODEL_ID" ] && MODEL_ID=$(sysctl -n hw.model 2>/dev/null)
  MODEL_NUMBER=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.model_number")
  CHIP=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.chip_type")
  [ -z "$CHIP" ] && CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  MEMORY=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.physical_memory")
  if [ -z "$MEMORY" ]; then
    MEMORY=$(awk -v b="$(sysctl -n hw.memsize 2>/dev/null || echo 0)" 'BEGIN{printf "%.0f GB", b/1e9}')
  fi
  SERIAL=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.serial_number")
  if [ -z "$SERIAL" ]; then
    SERIAL=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ {print $4}')
  fi
  HW_UUID=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.platform_UUID")
  if [ -z "$HW_UUID" ]; then
    HW_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4}')
  fi
  PROV_UDID=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.provisioning_UDID")
  ACTIVATION_RAW=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.activation_lock_status")
  case "$ACTIVATION_RAW" in
    activation_lock_disabled) ACTIVATION="Disabled" ;;
    activation_lock_enabled) ACTIVATION="Enabled" ;;
    *) ACTIVATION="${ACTIVATION_RAW:-Unknown}" ;;
  esac

  PROC_INFO=$(plist_get "$SYS_JSON" "SPHardwareDataType.0.number_processors")
  CPU_TOTAL=$(printf '%s' "$PROC_INFO" | awk -F'[: ]' '{print $2}')
  CPU_P=$(printf '%s' "$PROC_INFO" | awk -F'[: ]' '{print $3}')
  CPU_E=$(printf '%s' "$PROC_INFO" | awk -F'[: ]' '{print $4}')
  if [ -n "$CPU_TOTAL" ] && [ -n "$CPU_E" ] && [ "$CPU_E" != "0" ]; then
    CPU_DESC="$CPU_TOTAL cores ($CPU_P performance + $CPU_E efficiency)"
  elif [ -n "$CPU_TOTAL" ]; then
    CPU_DESC="$CPU_TOTAL cores"
  else
    CPU_DESC="$(sysctl -n hw.ncpu 2>/dev/null || echo '?') cores"
  fi

  OS_VERSION=$(plist_get "$SYS_JSON" "SPSoftwareDataType.0.os_version")
  BOOT_MODE=$(plist_get "$SYS_JSON" "SPSoftwareDataType.0.boot_mode")
  BOOT_MODE=$(printf '%s' "$BOOT_MODE" | tr '_' ' ')
  [ -z "$OS_VERSION" ] && OS_VERSION="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  KERNEL=$(uname -r 2>/dev/null)
  BOOT_EPOCH=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
  NOW=$(date +%s)
  if [ -n "$BOOT_EPOCH" ]; then
    UPTIME_SEC=$(( NOW - BOOT_EPOCH ))
  else
    UPTIME_SEC=0
  fi
  BOOT_DATE=$(human_date "$BOOT_EPOCH")
  UPTIME_DESC=$(format_duration "$UPTIME_SEC")
}

collect_dates() {
  SETUP_FILE="/var/db/.AppleSetupDone"
  SETUP_EPOCH=""
  SETUP_DAYS=""
  if [ -f "$SETUP_FILE" ]; then
    SETUP_EPOCH=$(stat -f %B "$SETUP_FILE" 2>/dev/null || printf '')
    if [ -n "$SETUP_EPOCH" ] && [ "$SETUP_EPOCH" -gt 0 ] 2>/dev/null; then
      SETUP_DAYS=$(( (NOW - SETUP_EPOCH) / 86400 ))
    fi
  fi

  INSTALL_JSON=$(system_profiler SPInstallHistoryDataType -json 2>/dev/null)
  FIRST_INSTALL_NAME=$(plist_get "$INSTALL_JSON" "SPInstallHistoryDataType.0._name")
  FIRST_INSTALL_ISO=$(plist_get "$INSTALL_JSON" "SPInstallHistoryDataType.0.install_date")

  OLDEST_RECEIPT=$(find /var/db/receipts -type f -exec stat -f "%B %N" {} + 2>/dev/null | sort -n | head -1)
  RECEIPT_EPOCH=""
  RECEIPT_PATH=""
  if [ -n "$OLDEST_RECEIPT" ]; then
    RECEIPT_EPOCH=${OLDEST_RECEIPT%% *}
    RECEIPT_PATH=${OLDEST_RECEIPT#* }
  fi

  WTMP_BEGIN=$(last reboot 2>/dev/null | tail -1 | sed 's/^wtmp begins //')
}

collect_nvram() {
  NVRAM_TEXT=$(nvram -p 2>/dev/null)
  BOOT_ARGS=$(printf '%s\n' "$NVRAM_TEXT" | awk '$1=="boot-args" {$1=""; sub(/^[ \t]+/,""); print; exit}')
  PANIC_INFO=$(printf '%s\n' "$NVRAM_TEXT" | grep -i '^PanicInfo' | head -1)
  CSR_ACTIVE=$(printf '%s\n' "$NVRAM_TEXT" | awk '$1=="csr-active-config" {print $2; exit}')
}

collect_security() {
  MDM_TEXT=$(profiles status -type enrollment 2>/dev/null)
  MDM_SUMMARY="unknown"
  if [ -n "$MDM_TEXT" ]; then
    MDM_SUMMARY="Not enrolled"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key=${line%%:*}
      val=${line#*: }
      if [ "$val" = "Yes" ]; then
        MDM_SUMMARY="Enrolled — check before purchase"
      fi
    done <<< "$MDM_TEXT"
  fi

  FV_TEXT=$(fdesetup status 2>/dev/null | head -1 | sed 's/^FileVault is //; s/\.$//')
  SIP_TEXT=$(csrutil status 2>/dev/null | head -1 | sed 's/^System Integrity Protection status: //; s/\.$//')
  GK_TEXT=$(spctl --status 2>/dev/null | head -1)
  SUPERVISED=$(printf '%s\n' "$NVRAM_TEXT" | awk '$1=="supervised" {print $2; exit}')

  FW_PASS_TEXT=""
  FW_PASS_ENABLED=0
  PROFILES_TEXT=""
  SUDO_SKIPPED=0
  if [ "$SUDO_MODE" = "1" ]; then
    if [ -t 0 ]; then
      if sudo -v; then
        FW_PASS_TEXT=$(sudo firmwarepasswd -check 2>&1)
        PROFILES_TEXT=$(sudo profiles -P 2>/dev/null | head -20)
      else
        SUDO_SKIPPED=1
      fi
    else
      SUDO_SKIPPED=1
    fi
    case "$FW_PASS_TEXT" in
      *"Password Enabled: Yes"*) FW_PASS_ENABLED=1 ;;
      *) FW_PASS_ENABLED=0 ;;
    esac
  fi
}

collect_storage() {
  NVME_JSON=$(system_profiler SPNVMeDataType -json 2>/dev/null)
  DISK=$(plist_get "$NVME_JSON" "SPNVMeDataType.0._items.0.bsd_name")
  if [ -z "$DISK" ]; then
    DISK_LIST_JSON=$(diskutil list -plist 2>/dev/null)
    DISK=$(plist_get "$DISK_LIST_JSON" "AllDisksAndPartitions.0.DeviceIdentifier")
  fi
  [ -z "$DISK" ] && DISK="disk0"

  DISK_PLIST=$(diskutil info -plist "$DISK" 2>/dev/null)
  if [ -z "$DISK_PLIST" ]; then
    DISK="disk0"
    DISK_PLIST=$(diskutil info -plist "$DISK" 2>/dev/null)
  fi

  # Prefer an internal disk. This avoids picking a mounted DMG or external disk
  # if system_profiler was unavailable and the fallback list started with one.
  INTERNAL_CHECK=$(plist_get "$DISK_PLIST" "Internal")
  case "$INTERNAL_CHECK" in
    1|true|TRUE|yes) : ;;
    *)
      for candidate in disk0 disk1 disk2 disk3 disk4; do
        CAND_PLIST=$(diskutil info -plist "$candidate" 2>/dev/null)
        [ -z "$CAND_PLIST" ] && continue
        CAND_INTERNAL=$(plist_get "$CAND_PLIST" "Internal")
        case "$CAND_INTERNAL" in
          1|true|TRUE|yes)
            DISK="$candidate"
            DISK_PLIST="$CAND_PLIST"
            break
            ;;
        esac
      done
      ;;
  esac

  DISK_MODEL=$(plist_get "$DISK_PLIST" "MediaName")
  [ -z "$DISK_MODEL" ] && DISK_MODEL=$(plist_get "$DISK_PLIST" "IORegistryEntryName")
  DISK_SIZE=$(plist_get "$DISK_PLIST" "TotalSize")
  SMART=$(plist_get "$DISK_PLIST" "SMARTStatus")
  BUS=$(plist_get "$DISK_PLIST" "BusProtocol")
  INTERNAL=$(plist_get "$DISK_PLIST" "Internal")
  SOLID=$(plist_get "$DISK_PLIST" "SolidState")

  WEAR=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.PERCENTAGE_USED")
  SPARE=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.AVAILABLE_SPARE")
  SPARE_THRESHOLD=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.AVAILABLE_SPARE_THRESHOLD")
  HOURS=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.POWER_ON_HOURS_0")
  CYCLES=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.POWER_CYCLES_0")
  UNSAFE=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.UNSAFE_SHUTDOWNS_0")
  MEDIA_ERRORS=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.MEDIA_ERRORS_0")
  UNITS_WRITTEN=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.DATA_UNITS_WRITTEN_0")
  UNITS_READ=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.DATA_UNITS_READ_0")
  TEMP_K=$(plist_get "$DISK_PLIST" "SMARTDeviceSpecificKeysMayVaryNotGuaranteed.TEMPERATURE")

  DF_LINE=$(df -k / 2>/dev/null | awk 'NR==2')
  TOTAL_KB=$(printf '%s\n' "$DF_LINE" | awk '{print $2}')
  FREE_KB=$(printf '%s\n' "$DF_LINE" | awk '{print $4}')
  FREE_GB=""
  FREE_PCT=""
  if [ -n "$TOTAL_KB" ] && [ -n "$FREE_KB" ] && [ "$TOTAL_KB" -gt 0 ] 2>/dev/null; then
    FREE_GB=$(awk -v k="$FREE_KB" 'BEGIN{printf "%.1f", k/1048576}')
    FREE_PCT=$(awk -v f="$FREE_KB" -v t="$TOTAL_KB" 'BEGIN{printf "%.1f", f*100/t}')
  fi
}

count_panic_files() {
  find "$1" -maxdepth 1 -type f -name '*.panic' 2>/dev/null | wc -l | tr -d ' '
}
count_panic_ips() {
  find "$1" -maxdepth 1 -type f -name '*.ips' -exec grep -l -E '"bug_type":"210"|panicString' {} + 2>/dev/null | wc -l | tr -d ' '
}
count_shutdown_stalls() {
  find "$1" -maxdepth 1 -type f -name '*.shutdownStall' 2>/dev/null | wc -l | tr -d ' '
}
count_jetsam() {
  find "$1" -maxdepth 1 -type f -name '*.ips' -exec grep -l '"bug_type":"298"' {} + 2>/dev/null | wc -l | tr -d ' '
}
count_ips() {
  find "$1" -maxdepth 1 -type f -name '*.ips' 2>/dev/null | wc -l | tr -d ' '
}
count_diag() {
  # Exclude dd_*.diag: macOS writes a microstackshot for the script's own
  # speed-test writes ("Event: disk writes, Action taken: none").
  find "$1" -maxdepth 1 -type f -name '*.diag' ! -name 'dd_*.diag' 2>/dev/null | wc -l | tr -d ' '
}

collect_stability() {
  DR="/Library/Logs/DiagnosticReports"
  UDR="$HOME/Library/Logs/DiagnosticReports"

  REBOOT_HISTORY=$(last reboot 2>/dev/null | head -10)
  PANICS=$(( $(count_panic_files "$DR") + $(count_panic_ips "$DR") ))
  STALLS=$(count_shutdown_stalls "$DR")
  JETSAM=$(count_jetsam "$DR")
  IPS=$(count_ips "$DR")
  DIAGS=$(count_diag "$DR")
  USER_PANICS=$(( $(count_panic_files "$UDR") + $(count_panic_ips "$UDR") ))
  USER_IPS=$(count_ips "$UDR")
  RETIRED=$(find "$DR/Retired" -type f 2>/dev/null | wc -l | tr -d ' ')
  USER_RETIRED=$(find "$UDR/Retired" -type f 2>/dev/null | wc -l | tr -d ' ')
  LATEST=$(ls -t "$DR" 2>/dev/null | grep -v '^dd_.*\.diag$' | head -5)

  INSTALL_LOG="/var/log/install.log"
  INSTALL_ERRORS=0
  if [ -r "$INSTALL_LOG" ]; then
    INSTALL_ERRORS=$(grep -c -i -E 'install failed|I/O error|disk error' "$INSTALL_LOG" 2>/dev/null || true)
    case "$INSTALL_ERRORS" in ''|*[!0-9]*) INSTALL_ERRORS=0 ;; esac
  fi
}

collect_battery() {
  POWER_JSON=$(system_profiler SPPowerDataType -json 2>/dev/null)
  BATT_CYCLES=$(plist_get "$POWER_JSON" "SPPowerDataType.0.sppower_battery_health_info.sppower_battery_cycle_count")
  BATT_HEALTH=""
  BATT_MAX=""
  if [ -n "$BATT_CYCLES" ]; then
    BATT_HEALTH=$(plist_get "$POWER_JSON" "SPPowerDataType.0.sppower_battery_health_info.sppower_battery_health")
    BATT_MAX=$(plist_get "$POWER_JSON" "SPPowerDataType.0.sppower_battery_health_info.sppower_battery_health_maximum_capacity")
  fi
}

collect_hardware() {
  DISPLAY_TEXT=$(system_profiler SPDisplaysDataType 2>/dev/null)
  GPU_MODEL=$(printf '%s\n' "$DISPLAY_TEXT" | awk -F': ' '/Chipset Model:/ {print $2; exit}')
  GPU_CORES=$(printf '%s\n' "$DISPLAY_TEXT" | awk -F': ' '/Total Number of Cores:/ {print $2; exit}')
  GPU_METAL=$(printf '%s\n' "$DISPLAY_TEXT" | awk -F': ' '/Metal Support:/ {print $2; exit}')
  DISPLAY_COUNT=$(printf '%s\n' "$DISPLAY_TEXT" | grep -c 'Resolution:' 2>/dev/null || true)
  case "$DISPLAY_COUNT" in ''|*[!0-9]*) DISPLAY_COUNT=0 ;; esac

  WIFI_IF=$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: Wi-Fi/ {getline; print $2; exit}')
  WIFI_POWER=""
  WIFI_LINK=""
  WIFI_PHY=""
  if [ -n "$WIFI_IF" ]; then
    WIFI_POWER=$(networksetup -getairportpower "$WIFI_IF" 2>/dev/null | sed 's/.*: //')
    WIFI_LINK=$(ifconfig "$WIFI_IF" 2>/dev/null | awk '/status:/ {print $2; exit}')
    AIRPORT_TEXT=$(system_profiler SPAirPortDataType 2>/dev/null)
    WIFI_PHY=$(printf '%s\n' "$AIRPORT_TEXT" | awk -F': ' '/Supported PHY Modes:/ {print $2; exit}')
  fi

  BT_TEXT=$(system_profiler SPBluetoothDataType 2>/dev/null)
  BT_STATE=$(printf '%s\n' "$BT_TEXT" | awk -F': ' '/State:/ {print $2; exit}')
  BT_CHIP=$(printf '%s\n' "$BT_TEXT" | awk -F': ' '/Chipset:/ {print $2; exit}')

  ETH_PORTS=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port:/ {port=$0; sub(/^Hardware Port: /,"",port); sub(/ \([^)]*\)$/,"",port); getline; dev=$2; print port" ("dev")"}' | grep -v '^Wi-Fi' 2>/dev/null)

  TB_TEXT=$(system_profiler SPThunderboltDataType 2>/dev/null | grep -E 'Thunderbolt/USB4 Bus|Status:|Speed:' | sed 's/^[[:space:]]*//' | head -12)

  USB_TEXT=$(system_profiler SPUSBDataType 2>/dev/null)
  USB_LINES=$(printf '%s\n' "$USB_TEXT" | wc -l | tr -d ' ')
  case "$USB_LINES" in ''|*[!0-9]*) USB_LINES=0 ;; esac
}

# ---------------------------------------------------------------------------
# Warnings and verdict
# ---------------------------------------------------------------------------
build_warnings() {
  WARNINGS=""

  if [ "$ACTIVATION" = "Enabled" ]; then
    add_warning "Find My / Activation Lock is ENABLED. The seller must sign out of iCloud/Find My before the trade."
  elif [ "$ACTIVATION" = "Unknown" ]; then
    add_warning "Activation Lock status is unknown. Confirm it is disabled before trading."
  fi

  if [ "$MDM_SUMMARY" != "Not enrolled" ]; then
    add_warning "MDM/DEP enrollment is not confirmed clean ($MDM_SUMMARY). Get written confirmation that it is removed."
  fi

  if [ "$SUPERVISED" = "true" ]; then
    add_warning "This Mac is supervised. Confirm with the seller that it is not organization-owned."
  fi
  if [ "$FV_TEXT" = "On" ]; then
    add_warning "FileVault is On. The seller must provide the password or erase the Mac before the trade."
  fi
  if [ "$FW_PASS_ENABLED" = "1" ]; then
    add_warning "Firmware password is ENABLED. The seller must remove it before the trade."
  fi
  if [ "$SUDO_MODE" = "1" ] && [ "$SUDO_SKIPPED" = "1" ]; then
    add_warning "Firmware password/profiles check was skipped (no terminal for sudo). Re-run --sudo interactively."
  fi
  if [ -n "$PROFILES_TEXT" ] && ! printf '%s' "$PROFILES_TEXT" | grep -qi 'no configuration profiles'; then
    add_warning "Installed configuration profiles were found. Review them with: sudo profiles -P"
  fi

  case "$SIP_TEXT" in
    *disabled*|*Custom*) add_warning "System Integrity Protection (SIP) is disabled or customized." ;;
  esac
  case "$GK_TEXT" in
    *disabled*) add_warning "Gatekeeper assessments are disabled." ;;
  esac

  if [ -n "$SMART" ] && [ "$SMART" != "Verified" ]; then
    add_warning "SMART status is not Verified ($SMART)."
  fi
  if [ -n "$WEAR" ] && [ "$WEAR" -ge 80 ] 2>/dev/null; then
    add_warning "SSD wear is high (${WEAR}% used)."
  elif [ -n "$WEAR" ] && [ "$WEAR" -ge 50 ] 2>/dev/null; then
    add_warning "SSD wear is moderate (${WEAR}% used)."
  fi
  if [ -n "$MEDIA_ERRORS" ] && [ "$MEDIA_ERRORS" -gt 0 ] 2>/dev/null; then
    add_warning "SSD reports $MEDIA_ERRORS media error(s)."
  fi
  if [ -n "$UNSAFE" ] && [ "$UNSAFE" -gt 0 ] 2>/dev/null; then
    if [ -n "$CYCLES" ] && [ "$CYCLES" -gt 0 ] 2>/dev/null; then
      UNSAFE_PCT=$(awk -v u="$UNSAFE" -v c="$CYCLES" 'BEGIN{printf "%.1f", u*100/c}')
      add_warning "SSD reports $UNSAFE unsafe shutdown(s) out of $CYCLES power cycles (~${UNSAFE_PCT}%). Usually forced power-offs or shutdown stalls; watch whether it increases."
    else
      add_warning "SSD reports $UNSAFE unsafe shutdown(s). Usually forced power-offs or shutdown stalls; watch whether it increases."
    fi
  fi
  if [ -n "$SPARE" ] && [ -n "$SPARE_THRESHOLD" ] && [ "$SPARE" -lt "$SPARE_THRESHOLD" ] 2>/dev/null; then
    add_warning "Available spare (${SPARE}%) is below threshold (${SPARE_THRESHOLD}%)."
  fi
  if [ -n "$FREE_PCT" ] && awk -v p="$FREE_PCT" 'BEGIN{exit !(p < 10)}'; then
    add_warning "Only ${FREE_PCT}% free space on the boot volume."
  fi

  [ "$PANICS" -gt 0 ] 2>/dev/null && add_warning "Found $PANICS kernel panic report(s)."
  [ "$STALLS" -gt 0 ] 2>/dev/null && add_warning "Found $STALLS shutdown stall report(s). Decode with: spindump -i <file>"
  [ "$USER_PANICS" -gt 0 ] 2>/dev/null && add_warning "Found $USER_PANICS user kernel panic report(s)."
  [ "$INSTALL_ERRORS" -gt 0 ] 2>/dev/null && add_warning "Install log contains $INSTALL_ERRORS error line(s)."

  if [ -n "$BOOT_ARGS" ]; then
    case "$BOOT_ARGS" in
      *-v*|*debug*|*keepsyms*|*amfi_get_out_of_my_way*|*-s*)
        add_warning "Unusual boot-args are set: $BOOT_ARGS"
        ;;
    esac
  fi
  if [ -n "$PANIC_INFO" ]; then
    add_warning "NVRAM contains PanicInfo (a previous panic was recorded)."
  fi
  if [ -n "$CSR_ACTIVE" ]; then
    case "$CSR_ACTIVE" in
      0|00000000|%00|0x0|0x00) : ;;
      *) add_warning "NVRAM csr-active-config is non-zero ($CSR_ACTIVE). SIP may have been customized." ;;
    esac
  fi

  case "$BATT_HEALTH" in
    *Service*|*Replace*|*Poor*) add_warning "Battery health is $BATT_HEALTH." ;;
  esac
}

compute_verdict() {
  VERDICT_LEVEL="ok"
  VERDICT_TEXT="No ownership or health blockers found by these checks."

  if [ "$ACTIVATION" = "Enabled" ]; then
    VERDICT_LEVEL="bad"
    VERDICT_TEXT="STOP: Find My / Activation Lock is ENABLED. Do not complete the trade until the seller removes it."
    return
  fi
  if [ "$ACTIVATION" = "Unknown" ]; then
    VERDICT_LEVEL="bad"
    VERDICT_TEXT="STOP: Activation Lock status is unknown. Confirm it is disabled before trading."
    return
  fi
  if [ "$MDM_SUMMARY" != "Not enrolled" ]; then
    VERDICT_LEVEL="bad"
    VERDICT_TEXT="STOP: MDM/DEP is not confirmed clean. Do not complete the trade until enrollment is removed."
    return
  fi
  if [ "$FW_PASS_ENABLED" = "1" ]; then
    VERDICT_LEVEL="bad"
    VERDICT_TEXT="STOP: Firmware password is ENABLED. The seller must remove it before the trade."
    return
  fi

  HEALTH_CHECK=0
  [ "$SUDO_MODE" = "1" ] && [ "$SUDO_SKIPPED" = "1" ] && HEALTH_CHECK=1
  [ "$SUPERVISED" = "true" ] && HEALTH_CHECK=1
  [ "$FV_TEXT" = "On" ] && HEALTH_CHECK=1
  case "$SIP_TEXT" in *disabled*|*Custom*) HEALTH_CHECK=1 ;; esac
  case "$GK_TEXT" in *disabled*) HEALTH_CHECK=1 ;; esac
  [ -n "$SMART" ] && [ "$SMART" != "Verified" ] && HEALTH_CHECK=1
  [ -n "$WEAR" ] && [ "$WEAR" -ge 50 ] 2>/dev/null && HEALTH_CHECK=1
  [ -n "$MEDIA_ERRORS" ] && [ "$MEDIA_ERRORS" -gt 0 ] 2>/dev/null && HEALTH_CHECK=1
  [ -n "$UNSAFE" ] && [ "$UNSAFE" -gt 0 ] 2>/dev/null && HEALTH_CHECK=1
  if [ -n "$PROFILES_TEXT" ] && ! printf '%s' "$PROFILES_TEXT" | grep -qi 'no configuration profiles'; then
    HEALTH_CHECK=1
  fi
  [ "$PANICS" -gt 0 ] 2>/dev/null && HEALTH_CHECK=1
  [ "$STALLS" -gt 0 ] 2>/dev/null && HEALTH_CHECK=1
  [ "$INSTALL_ERRORS" -gt 0 ] 2>/dev/null && HEALTH_CHECK=1
  case "$BATT_HEALTH" in *Service*|*Replace*|*Poor*) HEALTH_CHECK=1 ;; esac

  if [ "$HEALTH_CHECK" = "1" ]; then
    VERDICT_LEVEL="warn"
    VERDICT_TEXT="CHECK: No ownership blockers found, but review the health warnings before trading."
  fi
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------
print_header() {
  printf '%s\n' "${BOLD}macOS Quick Condition Report${NC}"
  printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'Host:      %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  printf 'Script:    mac-check.sh %s\n' "$VERSION"
}

print_quick_summary() {
  section "QUICK SUMMARY — CHECK THESE FIRST"
  note "Trade blockers are marked [STOP]. Health items to review are [CHECK]."

  kv "Serial number" "$SERIAL"
  kv "Model" "$MODEL_NAME ($MODEL_ID)"

  if [ "$ACTIVATION" = "Disabled" ]; then
    status_line "Find My / Activation Lock" "$ACTIVATION" ok
  else
    status_line "Find My / Activation Lock" "$ACTIVATION" bad
  fi

  if [ "$MDM_SUMMARY" = "Not enrolled" ]; then
    status_line "MDM / DEP enrollment" "$MDM_SUMMARY" ok
  else
    status_line "MDM / DEP enrollment" "$MDM_SUMMARY" bad
  fi

  if [ "$SUPERVISED" = "false" ]; then
    status_line "Supervised" "$SUPERVISED" ok
  elif [ "$SUPERVISED" = "true" ]; then
    status_line "Supervised" "$SUPERVISED" warn
  else
    status_line "Supervised" "${SUPERVISED:-unknown}" warn
  fi

  if [ "$SIP_TEXT" = "enabled" ] && [ "$GK_TEXT" = "assessments enabled" ]; then
    status_line "SIP / Gatekeeper" "SIP: $SIP_TEXT; Gatekeeper: $GK_TEXT" ok
  else
    status_line "SIP / Gatekeeper" "SIP: ${SIP_TEXT:-unknown}; Gatekeeper: ${GK_TEXT:-unknown}" warn
  fi

  if [ "$FV_TEXT" = "Off" ]; then
    status_line "FileVault" "Off" ok
  elif [ "$FV_TEXT" = "On" ]; then
    status_line "FileVault" "On (seller password/erase needed)" warn
  else
    status_line "FileVault" "${FV_TEXT:-unknown}" warn
  fi

  if [ "$SUDO_MODE" = "1" ]; then
    if [ "$SUDO_SKIPPED" = "1" ]; then
      kv "Firmware password" "not checked (sudo skipped)"
    elif [ "$FW_PASS_ENABLED" = "1" ]; then
      status_line "Firmware password" "ENABLED" bad
    elif printf '%s' "$FW_PASS_TEXT" | grep -qi 'Password Enabled: No'; then
      status_line "Firmware password" "Disabled" ok
    elif printf '%s' "$FW_PASS_TEXT" | grep -qi 'not supported'; then
      status_line "Firmware password" "not supported on this Mac" ok
    elif [ -n "$FW_PASS_TEXT" ]; then
      status_line "Firmware password" "$(printf '%s' "$FW_PASS_TEXT" | head -1)" warn
    else
      kv "Firmware password" "not reported"
    fi
    if [ -n "$PROFILES_TEXT" ]; then
      if printf '%s' "$PROFILES_TEXT" | grep -qi 'no configuration profiles'; then
        status_line "Configuration profiles" "none" ok
      else
        status_line "Configuration profiles" "$(printf '%s' "$PROFILES_TEXT" | head -1)" warn
      fi
    fi
  else
    kv "Firmware password" "not checked (use --sudo)"
  fi

  if [ "$SMART" = "Verified" ]; then
    status_line "SMART status" "$SMART" ok
  elif [ -n "$SMART" ]; then
    status_line "SMART status" "$SMART" warn
  else
    status_line "SMART status" "unknown" warn
  fi

  if [ -z "$WEAR" ]; then
    kv "SSD wear" "not exposed"
  elif [ "$WEAR" -lt 50 ] 2>/dev/null; then
    status_line "SSD wear" "${WEAR}% used" ok
  else
    status_line "SSD wear" "${WEAR}% used" warn
  fi

  if [ -z "$MEDIA_ERRORS" ]; then
    kv "SSD media errors" "not exposed"
  elif [ "$MEDIA_ERRORS" -eq 0 ] 2>/dev/null; then
    status_line "SSD media errors" "$MEDIA_ERRORS" ok
  else
    status_line "SSD media errors" "$MEDIA_ERRORS" warn
  fi

  if [ -z "$UNSAFE" ]; then
    kv "SSD unsafe shutdowns" "not exposed"
  elif [ "$UNSAFE" -eq 0 ] 2>/dev/null; then
    status_line "SSD unsafe shutdowns" "$UNSAFE" ok
  else
    if [ -n "$CYCLES" ] && [ "$CYCLES" -gt 0 ] 2>/dev/null; then
      UNSAFE_PCT=$(awk -v u="$UNSAFE" -v c="$CYCLES" 'BEGIN{printf "%.1f", u*100/c}')
      status_line "SSD unsafe shutdowns" "$UNSAFE (~${UNSAFE_PCT}% of cycles)" warn
    else
      status_line "SSD unsafe shutdowns" "$UNSAFE" warn
    fi
  fi

  if [ -n "$HOURS" ] || [ -n "$CYCLES" ] || [ -n "$UNITS_WRITTEN" ]; then
    [ -n "$HOURS" ] && kv "SSD power-on hours" "$HOURS"
    [ -n "$CYCLES" ] && kv "SSD power cycles" "$CYCLES"
    [ -n "$UNITS_WRITTEN" ] && kv "Data written" "$(format_data_units "$UNITS_WRITTEN")"
  else
    kv "SSD lifetime counters" "not exposed on this Mac"
  fi

  if [ -n "$UNSAFE" ] && [ "$UNSAFE" -gt 0 ] 2>/dev/null; then
    note "Unsafe shutdowns are cumulative; a low ratio is usually forced power-offs or shutdown stalls."
  fi

  if [ "$PANICS" -eq 0 ] 2>/dev/null; then
    status_line "Kernel panics" "$PANICS" ok
  else
    status_line "Kernel panics" "$PANICS" warn
  fi
  if [ "$USER_PANICS" -gt 0 ] 2>/dev/null; then
    status_line "User kernel panics" "$USER_PANICS" warn
  fi
  if [ "$STALLS" -eq 0 ] 2>/dev/null; then
    status_line "Shutdown stalls" "$STALLS" ok
  else
    status_line "Shutdown stalls" "$STALLS" warn
  fi
  if [ "$INSTALL_ERRORS" -gt 0 ] 2>/dev/null; then
    status_line "Install log errors" "$INSTALL_ERRORS" warn
  fi

  if [ -n "$BATT_CYCLES" ]; then
    if [ "$BATT_HEALTH" = "Good" ] || [ "$BATT_HEALTH" = "Normal" ]; then
      status_line "Battery" "cycle count $BATT_CYCLES, health ${BATT_HEALTH:-unknown}, max ${BATT_MAX:-unknown}" ok
    else
      status_line "Battery" "cycle count $BATT_CYCLES, health ${BATT_HEALTH:-unknown}, max ${BATT_MAX:-unknown}" warn
    fi
  else
    kv "Battery" "none (desktop Mac)"
  fi

  kv "Warranty check" "https://checkcoverage.apple.com/"
  kv "Serial to enter" "$SERIAL"
  if [ "$WARNING_COUNT" -gt 0 ] 2>/dev/null; then
    kv "Warnings" "$WARNING_COUNT (see the end of the report)"
  else
    kv "Warnings" "none"
  fi

  printf '\n'
  case "$VERDICT_LEVEL" in
    ok)   printf '  %sVERDICT: %s%s\n' "$GREEN" "$VERDICT_TEXT" "$NC" ;;
    warn) printf '  %sVERDICT: %s%s\n' "$YELLOW" "$VERDICT_TEXT" "$NC" ;;
    bad)  printf '  %sVERDICT: %s%s\n' "$RED" "$VERDICT_TEXT" "$NC" ;;
  esac
}

print_identity() {
  section "1. Identity"

  kv "Model" "$MODEL_NAME ($MODEL_ID)"
  [ -n "$MODEL_NUMBER" ] && kv "Model number" "$MODEL_NUMBER"
  kv "Chip" "$CHIP"
  kv "CPU" "$CPU_DESC"
  kv "Memory" "$MEMORY"
  kv "Serial number" "$SERIAL"
  kv "Hardware UUID" "$HW_UUID"
  [ -n "$PROV_UDID" ] && kv "Provisioning UDID" "$PROV_UDID"
  kv "macOS" "$OS_VERSION"
  kv "Kernel" "$KERNEL"
  [ -n "$BOOT_MODE" ] && kv "Boot mode" "$BOOT_MODE"
  kv "Last boot" "$BOOT_DATE"
  kv "Uptime" "$UPTIME_DESC"

  if [ "$ACTIVATION" = "Disabled" ]; then
    printf '  %-28s %s%s%s\n' "Activation Lock" "$GREEN" "Disabled" "$NC"
  elif [ "$ACTIVATION" = "Enabled" ]; then
    printf '  %-28s %s%s%s\n' "Activation Lock" "$RED" "ENABLED — do not buy until removed" "$NC"
  else
    printf '  %-28s %s%s%s\n' "Activation Lock" "$YELLOW" "$ACTIVATION" "$NC"
  fi

  if [ "$OPEN_WARRANTY" = "1" ] && [ -n "$SERIAL" ]; then
    if command -v pbcopy >/dev/null 2>&1; then
      printf '%s' "$SERIAL" | pbcopy 2>/dev/null && note "Serial copied to clipboard."
    fi
    open "https://checkcoverage.apple.com/" 2>/dev/null || true
  fi
}

print_dates() {
  section "2. Setup / install dates (reset-aware)"

  if [ -f "$SETUP_FILE" ]; then
    kv "Setup Assistant done" "$(human_date "$SETUP_EPOCH")"
    if [ -n "$SETUP_DAYS" ] && [ "$SETUP_DAYS" -ge 0 ] 2>/dev/null && [ "$SETUP_DAYS" -le 14 ] 2>/dev/null; then
      warn_line "This macOS install is only ${SETUP_DAYS} day(s) old — likely a fresh reset."
    fi
  else
    kv "Setup Assistant done" "not found"
    note "The .AppleSetupDone marker is missing. macOS may have been installed differently."
  fi

  if [ -n "$FIRST_INSTALL_ISO" ]; then
    kv "First macOS install" "$FIRST_INSTALL_NAME ($(iso_to_local "$FIRST_INSTALL_ISO"))"
  fi
  if [ -n "$RECEIPT_EPOCH" ]; then
    kv "Oldest package receipt" "$(human_date "$RECEIPT_EPOCH")"
    note "$(basename "$RECEIPT_PATH")"
  fi
  [ -n "$WTMP_BEGIN" ] && kv "Reboot log begins" "$WTMP_BEGIN"

  note "If this Mac was erased before testing, these dates show the reset, not the"
  note "original first boot. macOS does not keep the original activation date locally."
  note "A reset wipes: setup date, install history, reboot history, crash reports, logs."
  note "A reset does NOT wipe: serial, Activation Lock, MDM, battery cycles, SSD counters."
  note "The SSD SMART counters in section 4 survive a reset and show lifetime usage."
  note "Use the serial number + Apple coverage page for the original purchase date."
}

print_security() {
  section "3. Security / ownership / warranty"

  if [ -n "$MDM_TEXT" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key=${line%%:*}
      val=${line#*: }
      kv "$key" "$val"
    done <<< "$MDM_TEXT"
  else
    kv "MDM" "unknown (profiles command failed)"
  fi

  [ -n "$FV_TEXT" ] && kv "FileVault" "$FV_TEXT"
  [ -n "$SIP_TEXT" ] && kv "SIP" "$SIP_TEXT"
  [ -n "$GK_TEXT" ] && kv "Gatekeeper" "$GK_TEXT"
  [ -n "$SUPERVISED" ] && kv "Supervised" "$SUPERVISED"

  if [ "$SUDO_MODE" = "1" ]; then
    if [ "$SUDO_SKIPPED" = "1" ]; then
      kv "Firmware password" "not checked (sudo skipped)"
    elif [ -n "$FW_PASS_TEXT" ]; then
      kv "Firmware password" "$(printf '%s' "$FW_PASS_TEXT" | head -1)"
    else
      kv "Firmware password" "not reported"
    fi
    if [ -n "$PROFILES_TEXT" ]; then
      note "Installed configuration profiles:"
      printf '%s\n' "$PROFILES_TEXT" | sed 's/^/    /'
    fi
  else
    note "Firmware password not checked. Re-run with --sudo to check it."
    note "Installed profiles not checked. Re-run with --sudo (profiles -P)."
  fi

  kv "Warranty check" "https://checkcoverage.apple.com/"
  kv "Serial to enter" "$SERIAL"
  note "Apple has no public warranty API. Enter the serial manually on that page."
  note "The coverage page may show the estimated purchase date and coverage end date."
  note "For a used Mac, ask the seller for the original invoice as well."
}

print_storage() {
  section "4. SSD health"

  kv "Disk" "$DISK ($DISK_MODEL)"
  [ -n "$DISK_SIZE" ] && kv "Capacity" "$(format_bytes "$DISK_SIZE")"
  [ -n "$BUS" ] && kv "Bus" "$BUS"
  case "$INTERNAL" in
    1|true|TRUE|yes) kv "Internal" "Yes" ;;
    *) kv "Internal" "No" ;;
  esac
  case "$SOLID" in
    1|true|TRUE|yes) kv "Media" "SSD" ;;
    *) kv "Media" "HDD/other" ;;
  esac

  if [ "$SMART" = "Verified" ]; then
    printf '  %-28s %s%s%s\n' "SMART status" "$GREEN" "$SMART" "$NC"
  elif [ -n "$SMART" ]; then
    printf '  %-28s %s%s%s\n' "SMART status" "$RED" "$SMART" "$NC"
  else
    kv "SMART status" "not reported"
  fi

  if [ -n "$WEAR" ] || [ -n "$HOURS" ]; then
    [ -n "$WEAR" ] && kv "Wear (percentage used)" "${WEAR}%"
    if [ -n "$SPARE" ]; then
      if [ -n "$SPARE_THRESHOLD" ]; then
        kv "Available spare" "${SPARE}% (threshold ${SPARE_THRESHOLD}%)"
      else
        kv "Available spare" "${SPARE}%"
      fi
    fi
    if [ -n "$HOURS" ]; then
      DAYS=$(awk -v h="$HOURS" 'BEGIN{printf "%.0f", h/24}')
      kv "Power-on hours" "$HOURS (~${DAYS} days)"
    fi
    [ -n "$CYCLES" ] && kv "Power cycles" "$CYCLES"
    [ -n "$UNSAFE" ] && kv "Unsafe shutdowns" "$UNSAFE"
    [ -n "$MEDIA_ERRORS" ] && kv "Media errors" "$MEDIA_ERRORS"
    [ -n "$UNITS_WRITTEN" ] && kv "Data written" "$(format_data_units "$UNITS_WRITTEN")"
    [ -n "$UNITS_READ" ] && kv "Data read" "$(format_data_units "$UNITS_READ")"
    if [ -n "$TEMP_K" ] && [ "$TEMP_K" -gt 0 ] 2>/dev/null; then
      if [ "$TEMP_K" -gt 200 ] 2>/dev/null; then
        kv "Temperature" "$(awk -v k="$TEMP_K" 'BEGIN{printf "%.0f C", k-273.15}')"
      else
        kv "Temperature" "${TEMP_K} C"
      fi
    fi
    note "These counters live in the SSD controller and survive an erase/reinstall."
  else
    note "Detailed NVMe SMART counters are not exposed on this Mac."
    note "SMART status is still shown above. smartmontools can provide deeper data."
  fi

  if [ -n "$FREE_GB" ]; then
    kv "Free space" "${FREE_GB} GB (${FREE_PCT}%)"
  fi

  # Disk speed test
  if [ "$DO_SPEED" = "1" ]; then
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac-check.XXXXXX" 2>/dev/null || printf '')
    if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
      kv "Speed test" "skipped (could not create a temp dir)"
    else
      TEST_FILE="$TEST_DIR/disk-test.bin"
      AVAIL_KB=$(df -k "$TEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
      case "$AVAIL_KB" in ''|*[!0-9]*) AVAIL_KB=0 ;; esac
      NEED_KB=$(( SIZE_MB * 1024 + 262144 ))
      if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
        kv "Speed test" "skipped (need ~$(( NEED_KB / 1024 )) MB free)"
      else
        BEST_W=0
        BEST_R=0
        DIRECT_W="oflag=direct"
        DIRECT_R="iflag=direct"
        DIRECT_NOTE=""
        FAILED=0
        i=1
        while [ "$i" -le "$RUNS" ]; do
          sync
          W_OUT=$(dd if=/dev/zero of="$TEST_FILE" bs=1m count="$SIZE_MB" $DIRECT_W 2>&1)
          W_BYTES=$(printf '%s\n' "$W_OUT" | sed -n 's/.*(\([0-9][0-9]*\) bytes\/sec).*/\1/p' | tail -1)
          if [ -z "$W_BYTES" ]; then
            W_OUT=$(dd if=/dev/zero of="$TEST_FILE" bs=1m count="$SIZE_MB" 2>&1)
            W_BYTES=$(printf '%s\n' "$W_OUT" | sed -n 's/.*(\([0-9][0-9]*\) bytes\/sec).*/\1/p' | tail -1)
            DIRECT_W=""
            DIRECT_NOTE="direct I/O unavailable; results may be affected by cache"
          fi
          sync
          R_OUT=$(dd if="$TEST_FILE" of=/dev/null bs=1m $DIRECT_R 2>&1)
          R_BYTES=$(printf '%s\n' "$R_OUT" | sed -n 's/.*(\([0-9][0-9]*\) bytes\/sec).*/\1/p' | tail -1)
          if [ -z "$R_BYTES" ]; then
            R_OUT=$(dd if="$TEST_FILE" of=/dev/null bs=1m 2>&1)
            R_BYTES=$(printf '%s\n' "$R_OUT" | sed -n 's/.*(\([0-9][0-9]*\) bytes\/sec).*/\1/p' | tail -1)
            DIRECT_R=""
            DIRECT_NOTE="direct I/O unavailable; results may be affected by cache"
          fi
          [ -n "$W_BYTES" ] && [ "$W_BYTES" -gt "$BEST_W" ] 2>/dev/null && BEST_W=$W_BYTES
          [ -n "$R_BYTES" ] && [ "$R_BYTES" -gt "$BEST_R" ] 2>/dev/null && BEST_R=$R_BYTES
          i=$(( i + 1 ))
        done

        if [ "$BEST_W" -gt 0 ] 2>/dev/null; then
          kv "Sequential write" "$(format_speed "$BEST_W")"
        else
          kv "Sequential write" "failed"
          FAILED=1
        fi
        if [ "$BEST_R" -gt 0 ] 2>/dev/null; then
          kv "Sequential read" "$(format_speed "$BEST_R")"
        else
          kv "Sequential read" "failed"
          FAILED=1
        fi
        note "Test: ${SIZE_MB} MiB blocks, ${RUNS} run(s), best result, direct I/O (cache bypassed)."
        [ -n "$DIRECT_NOTE" ] && warn_line "$DIRECT_NOTE"
        [ "$FAILED" = "1" ] && add_warning "Disk speed test failed to complete."
      fi
    fi
  else
    kv "Speed test" "skipped (--no-speed)"
  fi
}

print_stability() {
  section "5. Stability / crash history"

  kv "Last boot" "$BOOT_DATE"
  kv "Uptime" "$UPTIME_DESC"

  if [ -n "$REBOOT_HISTORY" ]; then
    note "Recent reboots/shutdowns (from wtmp):"
    printf '%s\n' "$REBOOT_HISTORY" | sed 's/^/    /'
  fi

  kv "Kernel panics" "$PANICS"
  kv "Shutdown stalls" "$STALLS"
  kv "Jetsam (memory) events" "$JETSAM"
  kv "Other .ips reports" "$IPS"
  kv "App .diag reports" "$DIAGS"
  note "dd_*.diag write-monitoring reports from the speed test are excluded."
  [ "$RETIRED" -gt 0 ] 2>/dev/null && kv "Retired system reports" "$RETIRED"
  [ "$USER_PANICS" -gt 0 ] 2>/dev/null && kv "User kernel panics" "$USER_PANICS"
  [ "$USER_IPS" -gt 0 ] 2>/dev/null && kv "User .ips reports" "$USER_IPS"
  [ "$USER_RETIRED" -gt 0 ] 2>/dev/null && kv "Retired user reports" "$USER_RETIRED"

  if [ -n "$LATEST" ]; then
    note "Latest system reports:"
    printf '%s\n' "$LATEST" | sed 's/^/    /'
  fi

  if [ "$STALLS" -gt 0 ] 2>/dev/null; then
    note "Decode a shutdown stall report with: spindump -i <file>"
    note "It writes the readable report to /tmp/spindump.txt."
  fi

  kv "Install log errors" "$INSTALL_ERRORS"
  if [ "$INSTALL_ERRORS" -gt 0 ] 2>/dev/null; then
    warn_line "Recent install log contains:"
    grep -i -E 'install failed|I/O error|disk error' "$INSTALL_LOG" 2>/dev/null | tail -5 | sed 's/^/    /'
  fi

  note "After a reset, crash reports and logs only cover the new install."
  note "A clean reset often has no reports; use the SSD counters for lifetime history."

  if [ "$DEEP_LOGS" = "1" ]; then
    note "Scanning unified log (last 1h, this can take a few seconds)..."
    LOG_OUT=$(/usr/bin/log show --last 1h --style compact --predicate 'process == "kernel" AND messageType == error' 2>/dev/null)
    LOG_FILTER='Sandbox:|System Policy:|syscall-mach-denied|duplicate report|com.apple.log:|log run noninteractively'
    LOG_COUNT=$(printf '%s\n' "$LOG_OUT" | grep -v '^Timestamp' | grep -v '^$' | grep -v -E "$LOG_FILTER" | wc -l | tr -d ' ')
    kv "Kernel error lines (1h)" "$LOG_COUNT"
    note "Kernel errors are noisy; look for repeated hardware/I/O patterns, not the raw count."
    if [ "$LOG_COUNT" -gt 0 ] 2>/dev/null; then
      note "Last 5 filtered kernel errors (sandbox/policy noise removed):"
      printf '%s\n' "$LOG_OUT" | grep -v -E "$LOG_FILTER" | grep -v '^Timestamp' | grep -v '^$' | tail -5 | sed 's/^/    /'
    fi

    IO_OUT=$(/usr/bin/log show --last 1h --style compact --predicate 'eventMessage CONTAINS[c] "I/O error"' 2>/dev/null | grep -v 'com.apple.log:' | grep -v 'log run noninteractively')
    IO_COUNT=$(printf '%s\n' "$IO_OUT" | grep -v '^Timestamp' | grep -v '^$' | wc -l | tr -d ' ')
    kv "I/O error lines (1h)" "$IO_COUNT"
    [ "$IO_COUNT" -gt 0 ] 2>/dev/null && add_warning "Unified log contains $IO_COUNT I/O error line(s) in the last hour."

    SHUT_OUT=$(/usr/bin/log show --last 1h --style compact --predicate 'eventMessage CONTAINS[c] "Previous shutdown cause"' 2>/dev/null | grep -v 'com.apple.log:' | grep -v 'log run noninteractively' | grep -v '^Timestamp' | grep -v '^$' | tail -1)
    [ -n "$SHUT_OUT" ] && kv "Previous shutdown" "$SHUT_OUT"
  fi
}

print_nvram() {
  section "6. NVRAM / boot flags"

  if [ -n "$BOOT_ARGS" ]; then
    kv "boot-args" "$BOOT_ARGS"
  else
    kv "boot-args" "(none)"
  fi

  if [ -n "$PANIC_INFO" ]; then
    kv "PanicInfo" "present"
    note "$(printf '%s' "$PANIC_INFO" | cut -c1-200)"
  else
    kv "PanicInfo" "(none)"
  fi

  if [ -n "$CSR_ACTIVE" ]; then
    kv "csr-active-config" "$CSR_ACTIVE"
  else
    kv "csr-active-config" "(not set)"
  fi
}

print_hardware() {
  section "7. Hardware / ports"

  if [ -n "$GPU_MODEL" ]; then
    if [ -n "$GPU_CORES" ]; then
      kv "GPU" "$GPU_MODEL ($GPU_CORES cores)"
    else
      kv "GPU" "$GPU_MODEL"
    fi
  fi
  [ -n "$GPU_METAL" ] && kv "Metal" "$GPU_METAL"

  if [ "$DISPLAY_COUNT" -gt 0 ]; then
    kv "Displays detected" "$DISPLAY_COUNT"
    printf '%s\n' "$DISPLAY_TEXT" | awk -F': ' '/Resolution:/ {print "    "$2}' | head -4
  else
    kv "Displays detected" "0 (headless or not reported)"
  fi

  if [ -n "$WIFI_IF" ]; then
    kv "Wi-Fi" "${WIFI_POWER:-unknown} (interface ${WIFI_IF}, link ${WIFI_LINK:-unknown})"
    [ -n "$WIFI_PHY" ] && kv "Wi-Fi modes" "$WIFI_PHY"
  fi

  if [ -n "$BT_STATE" ]; then
    if [ -n "$BT_CHIP" ]; then
      kv "Bluetooth" "$BT_STATE ($BT_CHIP)"
    else
      kv "Bluetooth" "$BT_STATE"
    fi
  fi

  if [ -n "$ETH_PORTS" ]; then
    note "Hardware ports:"
    printf '%s\n' "$ETH_PORTS" | sed 's/^/    /'
  fi

  if [ -n "$TB_TEXT" ]; then
    note "Thunderbolt/USB4:"
    printf '%s\n' "$TB_TEXT" | sed 's/^/    /'
  fi

  if [ "$USB_LINES" -gt 1 ]; then
    note "USB (first 25 lines):"
    printf '%s\n' "$USB_TEXT" | grep -v '^[[:space:]]*$' | head -25 | sed 's/^[[:space:]]*//' | sed 's/^/    /'
  fi

  if [ -n "$BATT_CYCLES" ]; then
    kv "Battery" "cycle count $BATT_CYCLES, health ${BATT_HEALTH:-unknown}, max capacity ${BATT_MAX:-unknown}"
    note "Battery counters live in the battery controller and survive a reset."
  else
    kv "Battery" "none (desktop Mac)"
  fi
}

print_manual() {
  section "8. Manual checks (recommended)"

  note "Apple warranty / coverage: https://checkcoverage.apple.com/"
  note "  Enter serial: $SERIAL"
  note "Apple Diagnostics: shut down; hold power (Apple Silicon) or D (Intel) at startup."
  note "Firmware password: run with --sudo, or sudo firmwarepasswd -check"
  note "Installed configuration profiles: run with --sudo, or sudo profiles -P"
  note "Detailed SSD SMART: sudo smartctl -a /dev/$DISK  (only if smartmontools is installed)"
  note "Ports: test every USB, Thunderbolt, HDMI, Ethernet and audio port."
  note "Thermals/fans: run a CPU load and check that the Mac stays quiet and does not throttle."
  note "Sleep/wake: put the Mac to sleep and wake it several times."
  note "If the Mac was reset, ask the seller for the original invoice — it is the only"
  note "reliable proof of the original purchase date."
  note "If possible, run this script BEFORE the reset too: the original setup date,"
  note "install history and old crash reports are still present then."
}

print_warnings() {
  section "Warnings"

  WARNING_COUNT=$(printf '%s' "$WARNINGS" | grep -c '^- ' 2>/dev/null || true)
  case "$WARNING_COUNT" in ''|*[!0-9]*) WARNING_COUNT=0 ;; esac

  if [ "$WARNING_COUNT" -gt 0 ]; then
    printf '%s' "$WARNINGS"
  else
    ok_line "No obvious red flags found by the automated checks."
  fi

  note "This report is not a substitute for Apple Diagnostics or a physical inspection."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
collect_identity
collect_nvram
collect_security
collect_storage
collect_stability
collect_battery

build_warnings
compute_verdict
WARNING_COUNT=$(printf '%s' "$WARNINGS" | grep -c '^- ' 2>/dev/null || true)
case "$WARNING_COUNT" in ''|*[!0-9]*) WARNING_COUNT=0 ;; esac

print_header
print_quick_summary

if [ "$BRIEF" = "1" ]; then
  print_warnings
  note "Full details skipped (--brief). Run without --brief for all sections."
  exit 0
fi

print_identity
collect_dates
print_dates
print_security
print_storage
print_stability
print_nvram
collect_hardware
print_hardware
print_manual
print_warnings

exit 0
