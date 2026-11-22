# Functional Checks

A successful command is not proof that the feature works. Every reboot boundary and every major change needs evidence.

## Two kinds of checks

### auto

The script probes a concrete fact and reports it.

Examples:

- service is active
- session type and desktop are the expected values
- package is installed
- file exists with expected permissions
- command returns expected content
- monitor count is at least the required number

### confirm

The script shows the auto evidence and asks a specific question that only a human can answer.

Examples:

- "로그인 화면이 정상적으로 표시됩니까?"
- "두 모니터에 바탕화면이 표시됩니까?"
- "한글 입력과 Caps Lock이 정상 동작합니까?"
- "소리, 네트워크, 블루투스가 정상입니까?"
- "절전 후 복귀됩니까?"
- "서비스가 실제 요청에 응답합니까?"

Do not ask "잘 됩니까?" without showing what was checked.

## Check lifecycle

1. Run automatic probes.
2. Print the evidence.
3. Ask required confirmations.
4. Record pass, fail, or skipped with the boot or session ID.
5. If a required check fails, stop and show recovery.
6. If the user skips a non-required check, record the skip and warn.

## When checks must run

- after an apply step
- after the script is rerun following a reboot
- when the boot ID changes
- when the user session changes
- before destructive cleanup
- in final verification

## Deduplication

Store results with `boot_id` or `session_id`. Do not ask the same confirmation repeatedly in the same boot unless the user requests a recheck.

If a check result belongs to an older boot, do not count it as current evidence. Keep it as historical context only.

## Failure handling

A failed required check should:

- keep the phase open
- show the failing evidence
- offer a recovery path or a diagnostic command
- avoid advancing to cleanup
- not silently mark the check as passed

If the failure is environmental and outside the task, allow an explicit skip with a warning only when the design permits it. Record `skipped: true` and `reason`.

## Check registry

Keep checks declarative so the main flow stays readable.

```bash
check_auto "service_active" service_is_active "example.service"
check_auto "monitor_count" count_ge 2
check_confirm "login_screen" "로그인 화면이 정상적으로 표시됩니까?"
```

Adapt this to the chosen language and task. The names and JSON shape are not fixed; the behavior is.

## Example record

```json
{
  "id": "login_screen",
  "type": "confirm",
  "required": true,
  "status": "pass",
  "boot_id": "example-boot-id",
  "at": "2026-01-01T00:00:00Z"
}
```

Keep check records small. Do not put full command output in the state file; put long logs elsewhere and reference the log path if needed.

## Questions that work

Prefer observable questions:

- what should appear
- what should respond
- what should be possible
- what should survive a reboot or suspend

Avoid leading questions that assume success. Do not offer "yes" as the only prompt. Use a clear default and require an explicit affirmative for destructive or gate-passing answers.
