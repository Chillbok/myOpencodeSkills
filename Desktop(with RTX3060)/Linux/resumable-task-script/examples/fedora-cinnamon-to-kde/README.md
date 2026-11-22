# Fedora Cinnamon to KDE Plasma

This is a validated reference implementation, not a portable installer.

- Validated on Fedora Linux 45
- Date: 2026-11-22
- Task: convert an existing Fedora Cinnamon installation to Fedora KDE Plasma Desktop Edition while keeping `/home`
- Approach: one executable script, one JSON state file, reboot-safe verification gates

## What it demonstrates

- checking the current system before changing anything
- backing up packages, user configuration, system configuration, and recovery RPMs
- replacing the Fedora release identity with exact package versions
- configuring KDE keyboard settings for Wayland
- switching from SDDM to Plasma Login Manager without starting both at once
- verifying the new login path across three distinct boots
- requiring two boots with both monitors enabled
- combining automatic checks with user-confirmed functional checks
- deferring Cinnamon and SDDM removal until the gate passed
- providing a TTY recovery menu
- keeping the previous login manager installed until verification

## What is Fedora-specific

- package names such as `fedora-release-identity-cinnamon`, `fedora-release-identity-kde-desktop`, and `plasma-login-manager`
- exact versions such as `45-14`
- Plasma Login Manager and SDDM behavior
- `dnf5` flags
- the Cinnamon and KDE package lists
- NVIDIA and Secure Boot caveats

Versions and package names change. Re-check them on the target system.

## What is generic

- one script plus one JSON state file
- phase machine and `verify` before `apply`
- boot ID based resume and deduplication
- destructive cleanup after a verification gate
- automatic probes plus user-confirmed functional checks
- recovery mode
- single-writer lock and atomic state updates

## Lessons captured

- Do not confuse a package name with a binary or service name. On this system the package is `plasma-login-manager`, while the binary and service are `plasmalogin`.
- Do not treat `systemctl --dry-run` as a simulation; on the tested systemd version it changed enablement state.
- Do not use `systemctl mask --now` on a display manager from inside its graphical session.
- Disable the old display manager before enabling the new one, then verify the `display-manager.service` alias.
- `loginctl list-sessions` can contain a manager session. Resolve the graphical session with `loginctl show-user`.
- Use exact package versions for the release identity swap, or the package manager may select an older version from another repository.
- Use `--no-autoremove` for curated removal lists and build the installed list from `rpm -q` hits.
- Keep a recovery kit for the old login manager before removing it.

## Files

- `SwitchToPlasma.sh`: reference implementation. Paths in messages use `~/<workdir>`; the script derives its own directory at runtime.
- `state.example.json`: sanitized example of a completed state. Machine IDs, boot IDs, and transaction timestamps are placeholders.

## How to use this example

Read the phases, gates, and recovery behavior first. Then design the state schema and commands for the current task. Do not copy the package list or version numbers without verifying them.
