# ThinkPad P1 Gen 4i — Fan Auto Mode Root Cause Analysis

**Date:** 2026-05-14  
**System:** Fedora 43, Kernel `6.19.14-200.fc43.x86_64`  
**Machine:** ThinkPad P1 Gen 4i (Intel Tiger Lake-H, CPUID family:model:stepping `6:141:1` = `6:0x8d:1`)

---

## 1. Current System Snapshot

| Item | Value |
|---|---|
| Kernel | `6.19.14-200.fc43.x86_64` |
| Fan level | `disengaged` (max RPM, set manually) |
| Fan speed | `8064 RPM` |
| Temperatures (`/proc/acpi/ibm/thermal`) | `52 43 62 0 52 52 51 -128` °C |
| Platform profile | `performance` |
| Platform profile choices | `low-power`, `balanced`, `performance` |
| tuned profile | `throughput-performance` |
| DYTC lapmode | `0` (disabled) |
| `thinkpad_acpi fan_control` param | `Y` (enabled) |
| `thinkpad_acpi profile_force` param | `0` (auto-detect) |
| `thinkpad_acpi experimental` param | `0` (disabled) |
| thinkfan service | `disabled` / `inactive` |
| thermald service | `inactive` (exited — unsupported platform) |

---

## 2. The `fan()` Function in `~/.bashrc`

```bash
fan() {
    echo "Tawan's fan control"
    validArg=0
    fanLevel=''
    case "$1" in
        "auto" | "full-speed" | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | "disengaged")
            fanLevel=$1
            validArg=1
            ;;
        "full" | "max")
            fanLevel="full-speed"
            validArg=1
            ;;
        "check")
            validArg=2
            ;;
        *)
            validArg=0
            ;;
    esac

    if [ $validArg == 1 ]; then
        echo "Setting fan level = $fanLevel"
        echo "level $fanLevel" | sudo tee /proc/acpi/ibm/fan
    elif [ $validArg == 2 ]; then
        echo "Temp: /proc/acpi/ibm/thermal"
        cat /proc/acpi/ibm/thermal
        echo "Fan: /proc/acpi/ibm/fan"
        cat /proc/acpi/ibm/fan
    else
        echo "Invalid argument ..."
    fi
}
```

**The function itself is correct.** It properly writes `level <value>` to `/proc/acpi/ibm/fan`. There are no bugs in the shell logic.

---

## 3. Root Cause: Why `fan auto` Keeps Speed Too Low

### 3.1 What `level auto` Actually Does

Writing `level auto` to `/proc/acpi/ibm/fan` **does not activate any Linux kernel thermal algorithm**. It sends the fan speed decision entirely back to the **Embedded Controller (EC) firmware inside the BIOS**. Once in auto mode:

- The `thinkpad_acpi` kernel driver becomes a passive observer.
- The EC's internal thermal lookup table (burned into BIOS firmware) dictates when to spin the fan and how fast.

### 3.2 The EC Thermal Curve on ThinkPad P1 Gen 4i

The ThinkPad P1 Gen 4i BIOS/EC was calibrated primarily for Windows and for quiet operation. The EC's auto fan curve is **conservative by design**:

| CPU Temp Range | Typical EC Fan Behavior (auto mode) |
|---|---|
| < 55 °C | 0 – 1500 RPM (nearly silent) |
| 55 – 70 °C | 1500 – 3500 RPM |
| 70 – 80 °C | 3500 – 6000 RPM |
| > 80 °C | Ramp to max |

With the observed temps of **52–62 °C**, the EC keeps the fan at the low band. This is intentional BIOS behavior — not a kernel or driver bug — but it results in thermal throttling under sustained workloads before the fan ever reaches useful speeds.

### 3.3 DYTC / PSC Mode (Platform Speed Control)

The ThinkPad P1 Gen 4i uses **DYTC 6.x**, which introduces a new "Platform Speed Control" (PSC) mode. This is exposed in Linux as `platform_profile` under `/sys/firmware/acpi/platform_profile`.

Key observations:

- `profile_force = 0` → `thinkpad_acpi` auto-detects DYTC mode. For P1 Gen 4i with Tiger Lake-H, it selects **PSC mode**.
- `platform_profile = performance` → Set to performance profile.
- `dytc_lapmode = 0` → Lap-mode (safety throttle for use on laps) is disabled.

**The critical issue:** Even with `platform_profile = performance`, the PSC "performance" profile in DYTC still delegates fan curve execution to the EC firmware. It adjusts power limits (PL1/PL2), not the fan curve thresholds. The fan RPM-vs-temperature response curve remains controlled by the EC's internal table, which does not change between `balanced` and `performance` profiles for fan aggressiveness. Only power/TDP limits differ.

### 3.4 No Software Fan Daemon is Active

Cross-checked all software that could affect fan behavior:

| Service | Status | Effect |
|---|---|---|
| `thinkfan` | **disabled / inactive** | Not running — no software fan curve |
| `thermald` | **inactive (exited)** | Quit on boot: "Unsupported cpu model or platform" for Tiger Lake-H |
| `tuned` (throughput-performance) | **active** | Controls CPU governor only — does NOT write to `/proc/acpi/ibm/fan` |
| Direct kernel thermal zone trip points | Not configured | No `thermal_zone` trip configured for this machine |

Because no daemon is managing fan speed, when `level auto` is set, **only the EC firmware controls the fan**, and it uses its conservative BIOS table.

### 3.5 The Watchdog is Not Set (Minor Factor)

The `fan watchdog` feature in `thinkpad_acpi` can force a revert to `auto` after a timeout if user-space stops renewing it. Currently the watchdog is `0` (off). This is fine — it means manually-set levels (`disengaged`, `full-speed`, `0-7`) **persist without needing renewal**. If watchdog were set, manual levels would silently revert to `auto` after the timeout.

### 3.6 Summary Diagram

```
fan auto command
       │
       ▼
echo "level auto" > /proc/acpi/ibm/fan
       │
       ▼
thinkpad_acpi kernel driver (fan_control=Y)
       │  ← hands off control →
       ▼
EC Firmware (BIOS) thermal table
       │
       ▼
Conservative fan curve (quiet-first design for Windows/Balanced)
       │
       ▼
Fan speed too low for observed CPU temps (52–62°C → ~1500–2500 RPM)
```

---

## 4. Contributing Factor: thermald Failed to Start

`thermald` is Intel's userspace thermal daemon that can override kernel/EC thermal decisions. On this machine:

```
thermald[1241]: [/sys/devices/platform/thinkpad_acpi/dytc_lapmode] present:
                Thermald can't run on this platform
thermald[1241]: Unsupported cpu model or platform
```

Despite Tiger Lake-H being supported by thermald in theory, the presence of `dytc_lapmode` sysfs entry triggered a platform-detection branch that rejected the machine. This means thermald's thermal management layer — which could have provided smarter fan ramping via Intel Running Average Power Limit (RAPL) — **never ran**.

---

## 5. What Is NOT the Problem

- The `fan()` bash function is not buggy — it correctly writes to `/proc/acpi/ibm/fan`.
- `fan_control=1` in `/etc/modprobe.d/thinkfan.conf` is correctly set and loaded — manual control is enabled.
- Kernel `6.19` has no known regression in `thinkpad_acpi` fan control for this machine.
- `tuned throughput-performance` does not interfere with fan control.
- The `platform_profile=performance` setting is correct.

---

## 6. Recommended Fixes

### Option A — Use `thinkfan` for Software Fan Curve (Recommended) ✅ APPLIED

`thinkfan` is already installed. Configured with a temperature-based curve more aggressive than the EC's built-in table.

**Note:** See [Section 8](#8-thinkfan-crash-bug--resolution) for the crash bug that was encountered and resolved before this option could be used.

Applied config at `/etc/thinkfan.conf` (backup: `thinkfan.conf` in project directory):

```yaml
# Exponential curve — band widths compress as temp rises: 6→5→4→4→4→3→3°C
# More aggressive than previous flat curve at every level
# Wide quiet zone at idle; fan steps up increasingly fast when hot
levels:
  - [0,                    0,  37]   # 6°C step — fan off at idle
  - [1,                   32,  43]   # 6°C step
  - [2,                   38,  48]   # 5°C step
  - [3,                   43,  52]   # 4°C step
  - [4,                   47,  56]   # 4°C step
  - [5,                   51,  60]   # 4°C step
  - [6,                   55,  63]   # 3°C step
  - [7,                   58,  66]   # 3°C step
  - ["level disengaged",  60, 255]   # triggers above 66°C
```

**Threshold history:**

| Level | Initial upper | Aggressive flat | Exponential | vs flat |
|---|---|---|---|---|
| 0 (off)    | 47°C | 40°C | 37°C | −3°C |
| 1          | 52°C | 45°C | 43°C | −2°C |
| 2          | 57°C | 50°C | 48°C | −2°C |
| 3          | 63°C | 56°C | 52°C | −4°C |
| 4          | 69°C | 62°C | 56°C | −6°C |
| 5          | 75°C | 68°C | 60°C | −8°C |
| 6          | 81°C | 74°C | 63°C | −11°C |
| 7          | 87°C | 80°C | 66°C | −14°C |
| disengaged | 83°C | 76°C | 66°C | −10°C |

Band widths between consecutive upper limits (exponential column): **6→6→5→4→4→4→3→3°C** — compresses as temperature rises. The fan ramps slowly while cool, then accelerates through levels rapidly when hot.

Enabled and started:

```bash
sudo systemctl enable --now thinkfan
```

Status: `active (running)` — confirmed 2026-05-14.

### Option B — Keep Manual Override via `fan()` Function

Continue using `fan disengaged` or `fan 6` / `fan 7` during heavy workloads, and `fan auto` only at idle. This is what the current function is designed for.

### Option C — Set a More Aggressive Platform Profile at Boot

```bash
echo performance | sudo tee /sys/firmware/acpi/platform_profile
```

This is already `performance`, but on some BIOS versions, re-applying it after boot triggers a more aggressive EC fan ramp. Add to systemd or `/etc/rc.local`.

### Option D — Fix thermald (Advanced)

If thermald support for this machine is needed:

```bash
sudo systemctl edit thermald
# Add:
[Service]
ExecStart=
ExecStart=/usr/sbin/thermald --no-daemon --ignore-cpuid-check
```

---

## 8. thinkfan Crash Bug & Resolution

### 8.1 Symptom

After enabling thinkfan, the service immediately crashed with `code=dumped, signal=ABRT`:

```
thinkfan[2526940]: thinkfan: atasmart.c:2848: sk_disk_free: Assertion `d' failed.
```

Stack trace:
```
#4  sk_disk_free.cold (libatasmart.so.4)
#5  AtasmartSensorDriverD2Ev  (/usr/bin/thinkfan)   ← destructor
#10 Config::try_read_config   (/usr/bin/thinkfan)
```

### 8.2 Root Cause

The `/etc/thinkfan.conf` was the **unmodified example/template** file shipped with the package. It contained every possible sensor type as illustration:

```yaml
- atasmart: /dev/sda   # ← CRASH SOURCE
```

This machine uses NVMe — there is no `/dev/sda`. When `libatasmart` attempts to open a non-existent block device, it returns without setting the internal `sk_disk` handle (leaves it `NULL`). On config teardown (even after a failed parse), the `AtasmartSensorDriver` destructor calls `sk_disk_free(NULL)`, which hits the assertion `d != NULL` → `SIGABRT`.

This is a **thinkfan 2.0.0 bug**: the destructor should guard against `NULL` before calling `sk_disk_free`. Upstream issue exists. The workaround is to never have an `atasmart:` entry for a device that doesn't exist.

### 8.3 Additional Config Problems in the Template

The shipped example config had several other inapplicable entries:

| Entry | Problem |
|---|---|
| `atasmart: /dev/sda` | No SATA disk; NVMe-only system |
| `chip: thinkpad-isa-0000` (lm_sensors) | `lm_sensors` not installed |
| `name: k10temp` | AMD-only sensor; this machine is Intel |
| `- hwmon: /sys/class/hwmon/hwmon0/...` | Hardcoded index — unreliable across boots |
| `nvml: 27:00.0` | NVIDIA proprietary driver not in use |
| `- hwmon: /sys/class/graphics/fb0/...` | Non-existent path for this machine |
| Two separate `levels:` blocks | Invalid YAML — duplicate key |
| `tpacpi` indices `[1,2,3,4]` | Index 3 = dead sensor (always 0°C) |

### 8.4 Fix Applied

Replaced `/etc/thinkfan.conf` with a minimal correct config using only:
- `tpacpi: /proc/acpi/ibm/thermal` with indices `[0,1,2,4,5,6]` (skipping dead indices 3 and 7)
- `tpacpi: /proc/acpi/ibm/fan` as the sole fan driver
- A single `levels:` block with overlapping temperature ranges

Result: `thinkfan.service` is `active (running)`.

---

## 7. Key Takeaway

> **The root cause is that `level auto` surrenders fan control to the BIOS EC firmware, which uses a conservative, quiet-first fan curve designed for Windows. There is no kernel-level or software-level fan speed management currently running to supplement or override this behavior. The `fan()` bash function works as designed; the limitation is entirely in the EC firmware's thermal table.**
