# Failure Recovery

Design for interruption before it happens. A resumable script that cannot recover from a broken login path is not finished.

## Failure matrix

| Scenario | Detection | Safe behavior |
|---|---|---|
| Ctrl+C between commands | state still `in_progress` | rerun verifies and resumes; do not auto-retry destructive work |
| Power loss during a package or file transaction | package manager history, manifest comparison, missing files | read-only diagnosis; show recovery commands; do not auto-rollback |
| Terminal closed | lock released by process exit, state preserved | rerun; if the machine is mid-transaction, inspect first |
| Reboot not performed | boot ID equals the switch boot ID | print "reboot and rerun", exit without touching anything |
| New login path black screen | no graphical session, service failed, TTY available | provide TTY recovery card and a `--recover` menu |
| New path works but a feature does not | auto probe or user check fails | keep phase open; show evidence; offer diagnostics |
| State file corrupt | `jq` parse failure | restore `.bak`; otherwise quarantine and rebuild from system probes; reset gates conservatively |
| State file from another machine | fingerprint mismatch | archive and initialize fresh |
| Disk full | preflight and command errors | stop before destructive work; do not delete user data automatically |
| Two instances | `flock` conflict | report holder information and exit |
| Sudo expired | `sudo -n true` fails | prompt again before the privileged block |
| Package version changed | exact version missing | stop and resolve the version or repository issue; do not substitute silently |

## Recovery menu

Provide a mode that works from a text console and does not assume the new graphical path is healthy.

A useful menu:

```text
1) status
2) resume current phase
3) restore the previous login path
4) show recent log
5) quit
```

Rules:

- Status must be non-destructive.
- Restoring the previous login path must be safe even if the current one is crash-looping.
- Do not auto-select a destructive option.
- Do not run `reboot` for the user.
- Do not require the user to edit JSON.

## Keeping a recovery path

Before removing an old component, keep at least one of:

- the old package installed
- an offline package kit
- a second display manager or service
- a documented command to restore the old configuration

For graphical login changes, keep the old display manager installed until the new one has passed its verification boots. Download recovery packages before removing the old one.

## Rollback layers

1. **Configuration rollback**: restore the previous service alias, config file, or symlink. This can be fast and reversible.
2. **Package rollback**: use the package manager history or reinstall from a saved kit. Confirm with the user; do not run it automatically.
3. **Filesystem rollback**: restore a snapshot or backup. Use this only when configuration and package rollback are insufficient.

Document which layer the script will use and which layer is manual.

## State corruption

If the JSON cannot be parsed:

- preserve the corrupt file
- try the `.bak`
- if the backup is valid, restore it
- otherwise rebuild a conservative state from real system probes
- reset verification counters and require the gate again
- tell the user what was lost

Do not continue a destructive phase with an unknown state.

## TTY and boot recovery

Before a risky reboot, print a recovery card with:

- how to reach a TTY
- the exact status command
- the exact recovery command
- whether the old login path is still installed

Example:

```text
If the login screen does not appear:
  Ctrl+Alt+F3
  <workdir>/task.sh --recover

The previous display manager is still installed.
```

For boot failures that prevent a normal TTY, document the bootloader fallback, such as a rescue entry or a temporary kernel argument for a text target.

## Logs

- Keep logs private (`0600`).
- Log phase transitions and command exit codes, not secrets.
- Do not pipe an interactive privilege prompt into a logger that hides it.
- Truncate and redact error text stored in JSON.
