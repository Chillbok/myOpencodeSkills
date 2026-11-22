#!/usr/bin/env bash
# Optional minimal skeleton for a resumable task.
# This is a reference, not a required template. Adapt the phases, JSON schema,
# checks, and commands to the task.

set -Eeuo pipefail

DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
SELF="$DIR/$(basename -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
STATE="$DIR/state.json"
STATE_BAK="$DIR/state.json.bak"
LOCK="$DIR/.task.lock"
LOG_DIR="$DIR/logs"
LOG=""

umask 077

log() {
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"
  if [[ -n "$LOG" && -w "$LOG" ]]; then
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG"
  fi
}

warn() {
  printf '경고: %s\n' "$*" >&2
}

die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1" answer
  printf '%s [y/N]: ' "$prompt" >/dev/tty
  read -r answer </dev/tty || return 1
  [[ "$answer" =~ ^[Yy]$ ]]
}

need_tty() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '터미널에서 실행하세요: %s\n' "$SELF" >&2
    exit 2
  fi
}

now_utc() {
  date -u +%FT%TZ
}

boot_id() {
  cat /proc/sys/kernel/random/boot_id
}

state_init() {
  jq -n \
    --arg now "$(now_utc)" \
    --arg boot "$(boot_id)" \
    '{
      schema_version: 1,
      phase: "preflight",
      status: "pending",
      created_at: $now,
      updated_at: $now,
      boot_id: $boot,
      steps: {
        preflight: "pending",
        apply: "pending",
        verify: "pending",
        final_verify: "pending"
      },
      checks: [],
      transactions: [],
      last_error: null
    }' >"$STATE"
  chmod 600 "$STATE"
}

load_state() {
  if [[ ! -f "$STATE" ]]; then
    state_init
  fi
  if ! jq empty "$STATE" >/dev/null 2>&1; then
    if [[ -f "$STATE_BAK" ]] && jq empty "$STATE_BAK" >/dev/null 2>&1; then
      cp -f -- "$STATE_BAK" "$STATE"
      warn "state.json.bak에서 상태를 복구했습니다."
    else
      mv -f -- "$STATE" "$STATE.corrupt.$(date +%s)"
      state_init
      warn "손상된 상태를 보관하고 새로 시작합니다. 검증은 다시 해야 합니다."
    fi
  fi
  [[ "$(jq -r '.schema_version' "$STATE")" == "1" ]] || die "지원하지 않는 상태 버전입니다."
  state_update '.boot_id = $boot' --arg boot "$(boot_id)"
}

state_get() {
  jq -r "$1" "$STATE"
}

state_update() {
  local filter="$1"
  shift
  local tmp
  tmp=$(mktemp "$DIR/.state.XXXXXX") || die "임시 상태 파일을 만들 수 없습니다."
  if ! jq -e --arg ts "$(now_utc)" "$@" "($filter) | .updated_at = \$ts" "$STATE" >"$tmp"; then
    rm -f -- "$tmp"
    die "상태 갱신에 실패했습니다."
  fi
  jq -e '.schema_version == 1 and (.steps | type == "object")' "$tmp" >/dev/null \
    || { rm -f -- "$tmp"; die "상태 검증에 실패했습니다."; }
  chmod 600 "$tmp"
  cp -p -- "$STATE" "$STATE_BAK" 2>/dev/null || true
  mv -f -- "$tmp" "$STATE"
}

set_step() {
  state_update '.steps[$step] = $value' --arg step "$1" --arg value "$2"
}

set_phase() {
  state_update '.phase = $phase | .status = "in_progress"' --arg phase "$1"
}

record_check() {
  local id="$1" type="$2" required="$3" status="$4" detail="$5"
  state_update '.checks += [{
      "id": $id,
      "type": $type,
      "required": ($required == "true"),
      "status": $status,
      "detail": $detail,
      "boot_id": $boot,
      "at": $at
    }]' \
    --arg id "$id" --arg type "$type" --arg required "$required" \
    --arg status "$status" --arg detail "$detail" \
    --arg boot "$(boot_id)" --arg at "$(now_utc)"
}

check_auto() {
  local id="$1" required="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    record_check "$id" auto "$required" pass "$*"
  else
    record_check "$id" auto "$required" fail "$*"
    if [[ "$required" == "true" ]]; then
      die "필수 자동 검사 실패: $id"
    fi
    warn "선택 자동 검사 실패: $id"
  fi
}

check_confirm() {
  local id="$1" required="$2" question="$3"
  if confirm "$question"; then
    record_check "$id" confirm "$required" pass "$question"
  else
    record_check "$id" confirm "$required" fail "$question"
    if [[ "$required" == "true" ]]; then
      die "필수 확인 실패: $id"
    fi
    warn "선택 확인 실패: $id"
  fi
}

phase_preflight() {
  log "사전 점검"
  # Add task-specific checks here.
  set_step preflight done
  set_phase apply
}

phase_apply() {
  log "변경 적용"
  # Perform the change here, then verify it immediately.
  # If the task needs a reboot, save state and exit:
  #
  #   set_step apply done
  #   set_phase verify
  #   printf '재부팅 후 같은 스크립트를 다시 실행하세요.\n'
  #   exit 0
  set_step apply done
  set_phase verify
}

phase_verify() {
  log "변경 검증"
  # This is where post-reboot automatic checks and user confirmations belong.
  check_auto "example_service" true systemctl is-active --quiet systemd-logind
  check_confirm "example_feature" true "기능이 정상적으로 동작합니까?"
  set_step verify done
  set_phase final_verify
}

phase_final_verify() {
  log "최종 확인"
  # Re-check the most important facts here.
  set_step final_verify done
  state_update '.phase = "done" | .status = "done"'
  log "완료되었습니다."
}

show_status() {
  if [[ ! -f "$STATE" ]]; then
    printf '상태 파일이 없습니다. 스크립트를 실행하면 생성됩니다.\n'
    return 0
  fi
  jq -r '
    "단계: \(.phase) (\(.status))",
    "갱신: \(.updated_at)",
    "검사: \(.checks | length)개",
    "  통과: \([.checks[] | select(.status == "pass")] | length)",
    "  실패: \([.checks[] | select(.status == "fail")] | length)"
  ' "$STATE"
}

show_plan() {
  cat <<'EOF'
예정 단계:
  preflight -> apply -> verify -> final_verify -> done

이 스크립트는 재부팅을 직접 수행하지 않습니다.
EOF
  show_status
}

recover_menu() {
  need_tty
  load_state
  while true; do
    cat <<'EOF'

복구 메뉴
  1) 상태 보기
  2) 현재 단계 계속
  3) 종료
EOF
    printf '선택: '
    local choice
    read -r choice </dev/tty || exit 0
    case "$choice" in
      1) show_status ;;
      2) return 0 ;;
      3|q|Q) exit 0 ;;
      *) printf '1-3 중에서 선택하세요.\n' ;;
    esac
  done
}

run_main() {
  need_tty
  exec 9>"$LOCK"
  flock -n -E 75 9 || { printf '이미 실행 중입니다.\n' >&2; exit 75; }

  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG"
  chmod 600 "$LOG"

  load_state
  local i phase
  for i in $(seq 1 20); do
    phase=$(state_get '.phase')
    case "$phase" in
      preflight) phase_preflight ;;
      apply) phase_apply ;;
      verify) phase_verify ;;
      final_verify) phase_final_verify ;;
      done) printf '이미 완료되었습니다.\n'; exit 0 ;;
      *) die "알 수 없는 단계: $phase" ;;
    esac
  done
  die "단계 전환이 너무 많습니다."
}

case "${1:-}" in
  --status|status) show_status ;;
  --dry-run|dry-run) show_plan ;;
  --recover|recover) recover_menu; run_main ;;
  -h|--help|help) printf '사용법: %s [--status|--dry-run|--recover]\n' "$SELF" ;;
  "") run_main ;;
  *) printf '알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
esac
