#!/usr/bin/env bash
# Static checks for a script generated with the resumable-task-script skill.
# Usage:
#   validate-generated.sh <script.sh> [state.json]

set -Eeuo pipefail

SCRIPT="${1:-}"
STATE="${2:-}"
FAIL=0
WARN=0

say() { printf '%s\n' "$*"; }
ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

if [[ -z "$SCRIPT" || ! -f "$SCRIPT" ]]; then
  say "사용법: $0 <script.sh> [state.json]"
  exit 2
fi

if ! bash -n "$SCRIPT" 2>/dev/null; then
  fail "bash -n 문법 검사 실패"
else
  ok "bash -n 문법 검사"
fi

if [[ -x "$SCRIPT" ]]; then
  ok "실행 권한"
else
  warn "실행 권한이 없습니다: chmod +x \"$SCRIPT\""
fi

if grep -Eq '^(sudo[[:space:]]+)?(systemctl[[:space:]]+reboot|reboot)([[:space:]]|$)' "$SCRIPT"; then
  fail "스크립트가 직접 재부팅하는 명령을 포함합니다."
else
  ok "자동 재부팅 없음"
fi

if grep -Eq 'systemctl[[:space:]]+--dry-run' "$SCRIPT"; then
  fail "systemctl --dry-run은 실제 변경을 수행할 수 있습니다."
else
  ok "systemctl --dry-run 없음"
fi

if grep -Eq 'systemctl[[:space:]]+mask[[:space:]]+--now' "$SCRIPT"; then
  fail "systemctl mask --now는 실행 중인 세션을 끊을 수 있습니다."
else
  ok "systemctl mask --now 없음"
fi

if grep -Eq 'state\.json.*>[[:space:]]*"?\$STATE|echo .*>[[:space:]]*"\$STATE"' "$SCRIPT"; then
  warn "상태 파일을 직접 덮어쓰는 패턴이 보입니다. 원자적 갱신인지 확인하세요."
else
  ok "상태 파일 직접 덮어쓰기 패턴 없음"
fi

if command -v jq >/dev/null 2>&1; then
  if [[ -n "$STATE" ]]; then
    if [[ ! -f "$STATE" ]]; then
      fail "상태 파일이 없습니다: $STATE"
    elif ! jq empty "$STATE" >/dev/null 2>&1; then
      fail "상태 파일이 유효한 JSON이 아닙니다."
    else
      ok "상태 JSON 문법"
      if [[ "$(jq -r '.schema_version // empty' "$STATE")" == "" ]]; then
        fail "schema_version이 없습니다."
      else
        ok "schema_version"
      fi
      if [[ "$(jq -r '.phase // empty' "$STATE")" == "" ]]; then
        fail "phase가 없습니다."
      else
        ok "phase"
      fi
      if ! jq -e '.steps | type == "object"' "$STATE" >/dev/null 2>&1; then
        fail "steps가 객체가 아닙니다."
      else
        ok "steps"
      fi
    fi
  else
    warn "상태 파일을 인자로 넘기지 않았습니다. JSON 검사를 건너뜁니다."
  fi
else
  warn "jq가 없어 JSON 검사를 건너뜁니다."
fi

if grep -Eq 'mktemp[[:space:]]+/tmp|/tmp/[^"$ ]*state' "$SCRIPT"; then
  warn "/tmp 기반 상태 임시 파일은 재부팅 후 사라질 수 있습니다."
else
  ok "/tmp 상태 임시 파일 패턴 없음"
fi

if grep -Eq 'curl|wget' "$SCRIPT"; then
  warn "네트워크 다운로드가 있습니다. 실패 시 오프라인 복구 경로를 확인하세요."
fi

if grep -Eq 'chmod[[:space:]]+777' "$SCRIPT"; then
  fail "chmod 777 사용"
fi

say ""
if (( FAIL > 0 )); then
  say "결과: FAIL ${FAIL}개, WARN ${WARN}개"
  exit 1
fi
say "결과: 통과 (WARN ${WARN}개)"
