# System Maintenance Suite

Terminal-based toolkit for monitoring, cleanup, updates, backups, and diagnostics. Built entirely in Bash with a colorful TUI menu.

## Features
- Dashboard with CPU, memory, disk, uptime snapshots
- Disk cleanup with configurable targets and reclaim estimates
- Package management for Homebrew/apt/yum/dnf
- Backup creator for common personal directories with logging
- Process monitor using `htop` (if available) with interactive killer
- Internet speed test using `networkQuality` (macOS)
- Service manager for `launchctl`/`systemctl`
- Battery health insights for macOS and Linux
- Log analyzer with keyword filtering and tail controls
- Alert notifications for disk pressure (extendable to other metrics)
- File finder using `fzf` with preview and directory search
- Time and date display with calendar, timezone, and multiple formats
- File editor using `nvim` (Neovim) with permission and error handling

## Requirements
- Bash 4+
- Common Unix utilities (`ps`, `df`, `tar`, `curl`, etc.)
- Optional: `htop` (enhanced process monitor), `fzf` (file finder), `nvim` (file editor), `networkQuality` (macOS), `terminal-notifier`, `notify-send`, `upower`

## Usage
```bash
chmod +x system_suite.sh
./system_suite.sh
```

### Non-interactive Mode
Run specific modules for automation:
```bash
./system_suite.sh --non-interactive info
./system_suite.sh --non-interactive cleanup
./system_suite.sh --non-interactive update
./system_suite.sh --non-interactive find
./system_suite.sh --non-interactive time
./system_suite.sh --non-interactive edit
```

## Configuration
- Config: `~/.config/system_suite`
- Data/logs/backups: `~/.local/share/system_suite`
- Adjust thresholds (`ALERT_THRESHOLD_*`) or cleanup/backup targets inside `system_suite.sh`.
- Override disk usage target with `SYSTEM_SUITE_DISK_PATH=/desired/mount ./system_suite.sh`.

## Extending
- Add more alert conditions in `check_alerts()`
- Append modules to the menu + `--non-interactive` switch
- Hook additional notification channels inside `send_alert()`

## Troubleshooting
- Review recent actions in `~/.local/share/system_suite/system_suite.log`
- Run with `bash -x system_suite.sh` for verbose tracing

## Reliability Notes
- The suite now auto-falls back to workspace-local storage if home-directory paths are unavailable, ensuring logging still works in restricted environments.
- Critical operations (package updates, service actions, backups, deletions) run through guarded helpers that log failures instead of aborting the entire TUI.
- `pause` tolerates non-interactive shells so `--non-interactive` commands won't hang.
- Log/grep/tail operations report permission issues or missing matches instead of crashing; review `~/.local/share/system_suite/system_suite.log` (or the fallback within the project folder) for details.
- Internet speed tests use `networkQuality` on macOS; non-macOS systems will simply log that the command is unavailable.
