# Fedora XFCE Maintenance Script

A robust and secure Bash script designed for automated system maintenance and updates on Fedora XFCE. It ensures a safe update cycle by creating a verified Timeshift backup first. Videcoded.

## Features

* **Auto-Elevation:** Automatically asks for `sudo` privileges if run as a standard user.
* **Sleep Inhibition:** Prevents the system from suspending or going to idle sleep while maintenance is running (`systemd-inhibit`).
* **Safe Timeshift Snapshot:** 
  * Checks if the backup drive is connected and matches the expected UUID before starting.
  * Halts the entire update process and shuts down safely if the snapshot fails (preventing updates on an unprotected system).
* **Comprehensive Updates:**
  * System packages (`dnf upgrade` & `dnf autoremove`)
  * Flatpaks (System-wide & User)
  * Firmware (`fwupdmgr`)
  * Snap packages (if present)
  * Developer tools (`pipx`, `rustup`, global `npm` packages)
* **Detailed Logging:** Saves execution logs with timestamps in `/var/log/manutenzione/`.
* **Automatic Shutdown:** Powers off the system 30 seconds after completion.

---

## Prerequisites & Requirements

Before running the script, ensure you have the following installed and configured on your Fedora system:

* **Operating System:** Fedora Linux (optimized for XFCE desktop environment).
* **Privileges:** Root / `sudo` access.
* **Core Dependencies:**
  * `timeshift` (Required for safety snapshots)
  * `dnf`
  * `systemd` (for `systemd-inhibit`)
* **Optional Dependencies** (depending on your setup):
  * `flatpak`
  * `fwupd` / `fwupdmgr`
  * `snapd`
  * `pipx`, `rustup`, `npm`

---

## Installation & Usage

1. Clone or download the script to your local machine:
   ```bash
   git clone [https://github.com/your-username/your-repo-name.git](https://github.com/your-username/your-repo-name.git)
   cd your-repo-name

```

2. Make the script executable:
```bash
chmod +x manutenzione.sh

```


3. Run the script (it will automatically prompt for your password and elevate to root):
```bash
./manutenzione.sh

```


*(Alternatively, you can run it with `sudo ./manutenzione.sh`)*

---

## Configuration

If you want to bind the script to a specific backup drive, open `manutenzione.sh` and set your backup partition's UUID in the configuration section:

```bash
UUID_ATTESO="your-disk-uuid-here"

```

*(You can find your drive UUID using `lsblk -f`)*

## Logs

Execution logs are automatically saved under:

```text
/var/log/manutenzione/manutenzione_YYYY-MM-DD_HH-MM-SS.log

```

---
Created with Claude Sonnet 5.5
