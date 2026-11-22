# State Contract

The state file is the script's memory across reboots and sessions. It is not the source of truth about the machine.

## One state file

Use one JSON file, for example `state.json`, next to the script. Keep all progress, check evidence, and rollback references there.

- An automatic `state.json.bak` is acceptable for crash recovery.
- Do not create a second "real" state file.
- Logs are output, not state.
- Do not store passwords, tokens, private keys, or keyring contents.

## Minimal fields

The exact schema is task-specific. A practical starting point is:

```json
{
  "schema_version": 1,
  "phase": "preflight",
  "status": "pending",
  "updated_at": "2026-01-01T00:00:00Z",
  "system": {
    "machine_id": "...",
    "root_uuid": "...",
    "os": "...",
    "kernel": "..."
  },
  "boot_id": "...",
  "steps": {
    "preflight": "pending",
    "backup": "pending",
    "apply": "pending",
    "verify": "pending",
    "final_verify": "pending"
  },
  "checks": [],
  "transactions": [],
  "last_error": null
}
```

Add fields only when they support resume, verification, or rollback. Avoid turning the state into a log dump.

## State is evidence, not authority

On every run:

1. Read the JSON to know where to start.
2. Probe the real system.
3. If the probe contradicts the JSON, prefer the probe.
4. Reopen the earliest failed postcondition.
5. Never advance a destructive phase because a flag says `done`.

## Atomic updates

Write to a temporary file in the same directory, validate the JSON and required fields, then rename it over the state file. Create a backup of the previous file if the task is destructive.

Example shape:

```bash
tmp=$(mktemp "$DIR/.state.XXXXXX")
jq -e --arg ts "$(date -u +%FT%TZ)" \
  '.phase = $phase | .updated_at = $ts' \
  --arg phase "$phase" "$STATE" >"$tmp"
jq -e '.schema_version == 1' "$tmp" >/dev/null
chmod 600 "$tmp"
cp -p -- "$STATE" "$STATE.bak"
mv -f -- "$tmp" "$STATE"
```

Do not lock the state file itself if renaming replaces its inode. Lock a separate file or the directory.

## Schema versioning

Include `schema_version`. On an unknown version:

- stop
- preserve the old file
- explain how to migrate or reset
- do not silently reinterpret it

## System fingerprint

For machine-specific tasks, store enough identity to detect a reinstall or wrong machine:

- machine ID
- root filesystem UUID
- OS version
- kernel
- relevant driver or service version

If the fingerprint changes, archive the old state and start conservatively. A state file left in `/home` can survive an OS reinstall while the system no longer matches it.

## Boots, sessions, and deduplication

Use the kernel boot ID for boot boundaries:

```bash
cat /proc/sys/kernel/random/boot_id
```

Store a set of boot IDs, not a single counter, so rerunning in the same boot does not increment the count. If a check must be repeated, key it by boot ID or session ID.

For graphical sessions, find the real user session instead of the first session in `loginctl list-sessions`; manager sessions may also appear.

## External transactions

Record identifiers needed for rollback, such as package manager history IDs. Do not store the full output of every command.

If a transaction is interrupted, compare the installed state with the saved manifest. Do not automatically roll back. Offer a reviewed recovery step.

## Security

- State file mode `0600`, directory mode `0700`.
- Logs mode `0600`.
- Redact secrets from errors.
- Back up only what is needed. Exclude caches, large game libraries, browser profiles, SSH keys, and keyrings by default.
- Never source or `eval` state values.
- Treat the state as user-editable and therefore untrusted for security decisions.
