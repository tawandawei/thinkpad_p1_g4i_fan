# ThinkPad P1 Gen 4i — Fan Control Setup

Setup notes for re-installation. Replaces the conservative BIOS/EC fan curve with a software-controlled exponential curve via `thinkfan`.

**Machine:** ThinkPad P1 Gen 4i  
**OS:** Fedora 43+  
**Kernel:** 6.19+ (`thinkpad_acpi` driver built-in)

---

## Why This Is Needed

The ThinkPad P1 Gen 4i BIOS EC uses a quiet-first fan curve tuned for Windows. On Linux with `level auto`, the fan stays too slow even at 55–65°C. See `fan_auto_analysis.md` for the full root cause analysis.

---

## Step 1 — Allow Fan Control via thinkpad_acpi

Create `/etc/modprobe.d/thinkfan.conf`:

```bash
echo "options thinkpad_acpi fan_control=1" | sudo tee /etc/modprobe.d/thinkfan.conf
```

This enables writing to `/proc/acpi/ibm/fan`. Takes effect on next boot, or immediately via:

```bash
sudo rmmod thinkpad_acpi && sudo modprobe thinkpad_acpi fan_control=1
```

> **Note:** If the module is in use (it usually is), the rmmod will fail. A reboot is the safe option.

---

## Step 2 — Install thinkfan

```bash
sudo dnf install thinkfan
```

---

## Step 3 — Configure /etc/thinkfan.conf

The default installed config (`/etc/thinkfan.conf`) is an **example/template file** — do NOT use it as-is. It contains `atasmart: /dev/sda` which will crash thinkfan via a `libatasmart` null-pointer assertion if no SATA disk exists (this machine is NVMe-only).

Replace the entire file:

```bash
sudo tee /etc/thinkfan.conf > /dev/null << 'EOF'
# ThinkPad P1 Gen 4i - thinkfan config
# Kernel: 6.19+ / Fedora 43
# Sensor indices from /proc/acpi/ibm/thermal:
#   0=CPU  1=?  2=GPU/hot  3=DEAD(0°C)  4,5,6=board  7=DEAD(-128°C)

sensors:
  - tpacpi: /proc/acpi/ibm/thermal
    indices: [0, 1, 2, 4, 5, 6]

fans:
  - tpacpi: /proc/acpi/ibm/fan

# Exponential curve — band widths compress as temp rises: 6→5→4→4→4→3→3°C
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
EOF
```

A copy of this config is also kept as `thinkfan.conf` in this directory.

### Why these sensor indices?

Verify with `cat /proc/acpi/ibm/thermal`. Dead sensors must be excluded or thinkfan will use 0°C or -128°C as input and behave incorrectly.

```
temperatures:   52  43  62  0  52  52  51  -128
index:           0   1   2  3   4   5   6     7
                               ↑               ↑
                           DEAD (0°C)    DEAD (-128°C)
```

Indices used: `[0, 1, 2, 4, 5, 6]`

---

## Step 4 — Enable and Start the Service

```bash
sudo systemctl enable --now thinkfan
```

Verify it's running:

```bash
sudo systemctl status thinkfan
```

Expected output: `Active: active (running)`

---

## Step 5 — Verify Fan Control Works

```bash
cat /proc/acpi/ibm/fan
```

The `level` field should reflect whatever thinkfan is currently commanding (not `auto`).

---

## Troubleshooting

### thinkfan crashes with `sk_disk_free: Assertion 'd' failed`

The config contains an `atasmart: /dev/sda` entry but no SATA disk exists. This is a thinkfan 2.0.0 bug triggered by misconfiguration. Fix: remove all `atasmart:` lines from `/etc/thinkfan.conf`. Use the config in Step 3 above.

### `echo "level X" > /proc/acpi/ibm/fan` gives Permission denied

`fan_control=1` is not set. Check:

```bash
cat /sys/module/thinkpad_acpi/parameters/fan_control
# Should print: Y
```

If it prints `N`, the modprobe config is not loaded. Re-check Step 1 and reboot.

### Fan immediately goes back to auto / thinkfan overrides manual `fan` command

thinkfan takes exclusive control of the fan while running. Stop it first for manual control:

```bash
sudo systemctl stop thinkfan
fan disengaged   # or any level
```

Restart when done:

```bash
sudo systemctl start thinkfan
```

---

## Alternative: Manual Fan Control via `fan()` bash function

For quick manual overrides without thinkfan — or as the primary method if you prefer
hands-on control over a daemon. The full implementation is backed up in `fan_bashrc.sh`.

### Installation

Paste into `~/.bashrc` (or `source` the backup file from there):

```bash
## FAN SPEED
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
        ## ThinkPad specific path
        echo "level $fanLevel" | sudo tee /proc/acpi/ibm/fan
    elif [ $validArg == 2 ]; then
        echo "Temp: /proc/acpi/ibm/thermal"
        cat /proc/acpi/ibm/thermal
        echo "Fan: /proc/acpi/ibm/fan"
        cat /proc/acpi/ibm/fan
    else
        echo "Invalid argument: fanLevel: \"$1\", expected [auto|full|0-7|disengaged|full-speed|max]"
        echo "In case check, use \"fan check\""
    fi
}
```

### Usage

| Command | Effect |
|---|---|
| `fan check` | Print current temps (`/proc/acpi/ibm/thermal`) and fan state |
| `fan auto` | Hand control back to BIOS EC firmware |
| `fan 0` – `fan 7` | Set a specific speed level (0 = off, 7 = near-max) |
| `fan disengaged` | Maximum RPM — ignores EC thermal limits entirely |
| `fan full` / `fan max` | Alias for `full-speed` (same as disengaged) |

### Design notes

- Input validation uses a `case` statement covering all valid `thinkpad_acpi` level strings plus `full`/`max` aliases, cleanly rejecting anything else with a helpful error.
- `validArg` flag separates the three code paths (set / check / invalid) without duplication.
- `fan check` reads both `/proc/acpi/ibm/thermal` and `/proc/acpi/ibm/fan` in one call — useful for a quick sanity check before/after switching modes.
- Uses `sudo tee` instead of `sudo sh -c "echo ... > /proc/..."` — safer and avoids shell quoting issues with redirects and sudo.
- Requires `fan_control=1` (Step 1 in this README).

### Using alongside thinkfan

thinkfan owns the fan while running. Stop it first:

```bash
sudo systemctl stop thinkfan
fan disengaged    # or any level
# ... do your thing ...
sudo systemctl start thinkfan
```

---

## Reference

- `fan_auto_analysis.md` — root cause analysis of the EC fan curve issue and thinkfan crash bug
- `thinkfan.conf` — backup of the current working `/etc/thinkfan.conf`
- `fan_bashrc.sh` — backup of the `fan()` function for `~/.bashrc`
- `/proc/acpi/ibm/fan` — fan control interface
- `/proc/acpi/ibm/thermal` — raw temperature readings
- `man thinkfan.conf` — config file documentation
