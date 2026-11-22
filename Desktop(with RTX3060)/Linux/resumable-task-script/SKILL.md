---
name: Resumable Task Script
description: Use when a task requires reboots, multiple agent sessions, long-running steps, or interruption-safe execution. Designs and implements one executable script plus one JSON state file, validates the design with multiple subagents, and adds automatic probes plus user-confirmed functional checks before advancing.
---

# Resumable Task Script

Build multi-step work so the user runs **one executable script** and the task can resume after a reboot, a failed command, a closed terminal, or a lost agent session. State lives in **one JSON file** managed by the script.

This skill is for the execution architecture, not for a specific operating system or migration.

## When to use

Use this skill when any of the following is true:

- the task needs one or more reboots
- the agent session cannot survive the whole task
- the task has long-running or destructive steps
- partial failure would leave a confusing or unsafe state
- the user wants a single file to run, with only passwords and confirmations
- the task needs functional checks before continuing
- the work should be resumable and auditable

Typical examples:

- desktop environment or display manager changes
- edition, driver, firmware, or boot configuration changes
- multi-stage upgrades or migrations
- disk, network, or service changes that require reboots
- provisioning that must continue across sessions

Do not use this skill for a task that is genuinely one short command with no recovery or reboot boundary. A state machine would add risk without benefit.

## Hard contract

Every generated implementation must satisfy these rules.

1. **One user-facing entrypoint.** The user runs one script. Do not require a second check script, helper script, or manual state edit.
2. **One JSON state file.** Keep current progress in one JSON file. An automatic `state.json.bak` is allowed; do not scatter progress across multiple state files.
3. **No automatic reboot.** Save state, print the exact next action, and exit. The user reboots.
4. **Verify before apply.** Read the real system state before every phase. Never trust a JSON flag alone.
5. **Idempotent resume.** Re-running the same script must skip completed work and continue safely.
6. **Gate destructive actions.** Backups, recovery paths, and required checks must pass before deletion or replacement.
7. **Atomic state updates.** Write to a temporary file in the same directory, validate it, then rename. Never edit the live JSON in place.
8. **Single writer.** Use `flock` or an equivalent lock. Do not allow two concurrent runs.
9. **Functional checks are mandatory.** Combine automatic probes with concrete user confirmations at reboot boundaries and after major changes.
10. **Final verification uses real evidence.** Do not declare success from script logs or JSON status alone.

The user must never need to edit the JSON. If manual repair is required, provide a script mode such as `--recover` or `--status`.

## Workflow

### 1. Discover and define

- Inspect the current system and the target state.
- Identify reboot boundaries and irreversible actions.
- List recovery paths and what must remain installed until the end.
- Define what "working" means in observable terms.

### 2. Design the phase machine

- Give every phase a narrow purpose.
- Split each phase into `verify()` and `apply()`.
- Define the postcondition that proves the phase is done.
- Define the next phase only after that postcondition passes.
- Put destructive cleanup after verification gates.

### 3. Design the state file

- Choose a schema that fits the task.
- Do not copy the example schema blindly.
- Keep the minimum evidence needed to resume and audit.
- Include a schema version and a system fingerprint when the task is machine-specific.
- Store secrets, passwords, tokens, and keyring contents outside the state file.

### 4. Validate the design with subagents

This step is mandatory before writing the implementation.

Spawn multiple subagents in parallel. For reboot-spanning or destructive work, use at least three:

1. **State machine and JSON review**
   - transitions, idempotency, atomic writes, reboot resumption, gate bypass, corruption recovery
2. **Environment and command review**
   - actual commands, package and service names, permissions, locales, exit codes, session detection
3. **Failure, recovery, and UX review**
   - power loss, partial transactions, recovery menu, misleading prompts, one-script experience

Tell every subagent: **read-only, do not modify files, do not run sudo, do not run real package transactions**. Allow read-only simulations where useful.

Consolidate findings as P0, P1, and P2. Fix every P0 in the design before implementation. If a P0 requires a significant redesign, run another validation round. Do not write the final script while known P0 issues remain.

If subagents are unavailable, perform the same three review passes sequentially and state that limitation explicitly.

### 5. Implement and validate

- Build the script and the JSON state file.
- Add `--status`, `--dry-run`, and `--recover`.
- Validate syntax, JSON, state transitions, and forbidden patterns.
- Run non-destructive dry-runs and status checks.
- Prefer running a static validator before handing the script to the user.

### 6. Hand off and resume

- Tell the user the one command to run.
- Explain that sudo passwords and confirmations are the only inputs.
- On a reboot boundary, the script must print the next command and exit.
- After reboot or interruption, the same script reads the JSON and resumes.
- Do not ask the user to edit JSON or run a second script.

## Mandatory functional checks

The script must check that the feature actually works, not just that a command exited zero.

Use two check types:

- **auto**: the script probes a concrete fact
- **confirm**: the script shows evidence and asks the user a specific, observable question

### When to run checks

- immediately after an apply step
- after the script is rerun following a reboot
- when the session or boot changes
- before a destructive cleanup phase
- in final verification

### Gate rules

- A required check that fails blocks the next phase.
- A failed check must offer recovery or a clear next diagnostic step.
- Do not ask the same check twice in the same boot or session unless the user requests `--recheck`.
- Store the check result with the boot or session identifier and a timestamp.
- Automatic probes should be shown to the user before asking for confirmation.
- Ask concrete questions, not "does everything work?"

Examples:

- "로그인 화면이 정상적으로 표시됩니까?"
- "두 모니터에 바탕화면이 표시됩니까?"
- "한글 입력과 Caps Lock이 정상 동작합니까?"
- "절전 후 복귀됩니까?"
- "서비스가 요청에 응답합니까?"
- "예상한 파일이 생성되었습니까?"

A check record should capture at least:

```json
{
  "id": "login_screen",
  "type": "confirm",
  "required": true,
  "status": "pass",
  "boot_id": "...",
  "at": "..."
}
```

Adapt the field names to the task. The concept is mandatory; the exact JSON shape is not.

## Phase template

Use this as a starting point, not a rigid sequence.

```text
preflight
backup
apply
await-reboot
verify
destructive-cleanup
final-verify
done
```

A phase needs:

```text
id
purpose
verify predicate
apply action
required checks
next phase
recovery action
```

## State file guidance

- `phase`: current step
- `status`: pending, in progress, awaiting reboot, failed, done
- `steps`: per-step state
- `checks`: evidence and confirmations
- `boot_id` / `session_id`: resume and deduplication
- `system`: fingerprint such as machine ID, root UUID, OS version, kernel, driver
- `transactions`: external operations needed for rollback, such as package manager history IDs
- `last_error`: short, redacted diagnostic text

Treat the JSON as evidence and ordering. Re-probe the system on every run. If the state and the system disagree, prefer the probed system state and reopen the earliest failed postcondition.

## One-script UX

The normal interaction is:

```text
user runs one file
  -> script reports status
  -> script performs safe checks
  -> script asks for sudo password when needed
  -> script shows a change plan and asks for confirmation
  -> script saves state and exits at a reboot boundary
  -> user reboots
  -> user runs the same file
  -> script verifies and asks functional questions
  -> script continues only after required checks pass
```

The script should never:

- call `reboot` or `systemctl reboot`
- require the user to edit the JSON
- hide a password prompt behind a log pipe
- rely on translated command output for control flow
- use `systemctl --dry-run` as a simulation
- delete a recovery path before the final gate

## Reference material is not a mandate

The example implementation and minimal skeleton are references. Do not copy them blindly.

Choose the state schema, phase names, check framework, and commands that fit the task. Preserve the contract in this SKILL.md even when the implementation looks different.

If the example conflicts with the current system, the current system wins. Re-verify package names, service names, versions, and command flags.

## Files

- `references/design-contract.md`: phase design, gates, and subagent validation protocol
- `references/state-contract.md`: JSON state, atomic updates, idempotency, security
- `references/functional-checks.md`: automatic and user-confirmed checks
- `references/failure-recovery.md`: interruption, recovery, rollback, UX
- `examples/fedora-cinnamon-to-kde/`: complete validated Fedora 45 example
- `examples/minimal-skeleton.sh`: optional generic skeleton
- `examples/state.schema.json`: optional reference schema
- `scripts/validate-generated.sh`: static checks for a generated script

## Example caveat

The Fedora example was validated on Fedora Linux 45 in November 2026. It is a snapshot, not a portable installer. Package names, versions, and display-manager behavior can change. Always re-check the target system before using any command from an example.
