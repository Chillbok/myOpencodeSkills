# Design Contract

This reference explains how to turn a long, interruptible task into a phase machine and how to validate the design before implementation.

## 1. Define the task boundary

Write down:

- the starting state
- the target state
- what the user will observe when it works
- which actions are reversible
- which actions are destructive
- which actions require a reboot
- which actions require a new session or a new boot to verify
- what must remain available for recovery

Do not start with commands. Start with states and evidence.

## 2. Split by evidence, not by command count

A phase is a unit that can be verified. It is not just a group of commands.

Bad split:

```text
phase 1: run five commands
phase 2: run four commands
```

Better split:

```text
phase 1: target package set is installed and service is enabled
phase 2: the new session is active after reboot
phase 3: the required feature works and the old path is still available
phase 4: old packages are removed only after the gate
```

Each phase should answer: "What fact proves this phase is finished?"

## 3. Use verify before apply

Every phase should have two paths:

```text
verify():
  if the postcondition is already true, mark done and skip apply

apply():
  perform the change, then run verify again
```

This makes the script idempotent. A rerun should not repeat a successful destructive action.

If verification cannot prove the postcondition, the phase stays open. Do not advance because a command exited zero.

## 4. Put checks at boundaries

Functional checks belong at:

- after an apply step
- after a reboot
- after a session change
- before destructive cleanup
- in final verification

A check should show evidence first, then ask the user if a human observation is needed.

Example:

```text
자동 검사:
  - plasmalogin.service: active
  - session type: wayland
  - desktop: KDE
  - enabled monitors: 2

사용자 확인:
  두 모니터에 바탕화면이 정상적으로 표시됩니까? [y/N]
```

## 5. Gate destructive actions

Before a destructive phase, require:

- backup completed and verified
- recovery path present
- all prior required checks passed
- the target state is verified on the real system
- the user has seen the exact items to be removed or replaced

A JSON flag is not enough. Re-check the real system inside the destructive phase itself, not only in the phase dispatcher.

## 6. Make recovery a first-class path

Every design should answer:

- What if the machine reboots unexpectedly?
- What if the terminal closes mid-command?
- What if the new configuration does not start?
- What if a package transaction is interrupted?
- What if the state file is corrupt?
- What if the user wants to stop?

Provide a recovery mode that is safe to run from a TTY, and a clear card of commands before any risky reboot.

## 7. Subagent validation protocol

Run this after the design is written and before implementation.

### Agent 1: state machine and JSON

Prompt focus:

- Are phase transitions complete and idempotent?
- Can the same boot be counted twice?
- What happens after a partial write or a corrupt JSON file?
- Is the lock correct?
- Does the script trust JSON instead of the system?
- What happens if a package version changes between runs?

### Agent 2: environment and commands

Prompt focus:

- Do the exact commands exist and work on this machine?
- Are package, binary, and service names correct?
- Is session detection correct with multiple sessions?
- Are locale-dependent parses avoided?
- Are exit codes interpreted correctly?
- Does the script use a destructive command as a "dry run"?

### Agent 3: failure recovery and UX

Prompt focus:

- What happens on power loss, Ctrl+C, or terminal close?
- What if the new login path fails and there is no GUI?
- Can the user get stuck because a required check cannot pass?
- Is the one-script promise preserved?
- Are prompts concrete and answerable?
- Are secrets or keyrings exposed in backups or logs?

### Rules for subagents

- Tell them explicitly: read-only, no file creation, no sudo, no real install/remove transactions.
- Ask for P0, P1, P2 findings and exact corrections.
- Do not accept a design with unresolved P0 findings.
- If a P0 fix changes the architecture, run another review round.
- If subagents are unavailable, do the three passes sequentially and disclose that.

## 8. Design review checklist

- [ ] Every phase has a verify predicate.
- [ ] Every apply is idempotent.
- [ ] Reboot boundaries are explicit.
- [ ] Functional checks are defined for every boundary.
- [ ] Destructive actions are gated.
- [ ] Recovery is available before cleanup.
- [ ] State writes are atomic.
- [ ] One writer is enforced.
- [ ] JSON schema fits the task and does not leak secrets.
- [ ] The user only needs one script and credentials.
- [ ] Multiple subagents reviewed the design before implementation.
