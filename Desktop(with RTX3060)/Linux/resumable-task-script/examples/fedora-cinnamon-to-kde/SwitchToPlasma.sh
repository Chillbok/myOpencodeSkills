#!/usr/bin/env bash
# SwitchToPlasma.sh
# Fedora Cinnamon -> Fedora KDE Plasma migration helper.
# The user runs this file and enters the sudo password when asked.
# The script never reboots the machine.

set -Eeuo pipefail

trap '__rc=$?; printf "\n오류: 예상치 못한 실패 (exit %s, line %s)\n" "$__rc" "$LINENO" >&2; printf "다시 실행하면 저장된 단계부터 이어서 진행합니다.\n" >&2' ERR

DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
SELF="$DIR/$(basename -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
STATE="$DIR/state.json"
STATE_BAK="$DIR/state.json.bak"
BACKUP_ROOT="$DIR/backups"
LOG_DIR="$DIR/logs"
LOCK_FILE="$DIR/.switch.lock"
UMASK=077

SCHEMA_VERSION=1
TARGET_BOOTS=3
PHASES=(preflight backup branding keyboard plm_switch plm_verify package_removal sddm_removal user_cleanup final_verify done)

umask "$UMASK"

LOG=""

# ------------------------------------------------------------
# basic output
# ------------------------------------------------------------

log() {
  local msg="$*"
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$msg"
  if [[ -n "$LOG" && -w "$LOG" ]]; then
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$msg" >>"$LOG"
  fi
}

warn() {
  local msg="$*"
  printf '경고: %s\n' "$msg" >&2
  if [[ -n "$LOG" && -w "$LOG" ]]; then
    printf '경고: %s\n' "$msg" >>"$LOG"
  fi
}

die() {
  local msg="$*"
  printf '오류: %s\n' "$msg" >&2
  if [[ -n "$LOG" && -w "$LOG" ]]; then
    printf '오류: %s\n' "$msg" >>"$LOG"
  fi
  exit 1
}

header() {
  printf '\n============================================================\n'
  printf ' %s\n' "$*"
  printf '============================================================\n'
}

pause_enter() {
  printf '\n계속하려면 Enter를 누르세요. '
  read -r _ </dev/tty || true
}

confirm() {
  local prompt="$1" ans
  printf '%s [y/N]: ' "$prompt" >/dev/tty
  read -r ans </dev/tty || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

need_tty() {
  if [[ -t 0 && -t 1 ]]; then
    return 0
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] && command -v konsole >/dev/null 2>&1; then
    exec konsole -e "$SELF" "$@"
  fi
  printf '이 스크립트는 터미널에서 실행해야 합니다.\n' >&2
  printf '예: %s\n' "$SELF" >&2
  exit 2
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "필수 명령이 없습니다: $c"
  done
}

ensure_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  printf '\n관리자 권한이 필요합니다. sudo 암호를 입력하세요.\n' >/dev/tty
  sudo -v || die "sudo 인증에 실패했습니다."
}

run_root() {
  ensure_sudo
  sudo "$@"
}

# ------------------------------------------------------------
# state handling
# ------------------------------------------------------------

now_utc() {
  date -u +%FT%TZ
}

current_boot_id() {
  cat /proc/sys/kernel/random/boot_id
}

system_machine_id() {
  cat /etc/machine-id 2>/dev/null || printf 'unknown'
}

system_root_uuid() {
  findmnt -no UUID / 2>/dev/null || printf 'unknown'
}

system_fedora_version() {
  rpm -q --qf '%{VERSION}' fedora-release-common 2>/dev/null || printf 'unknown'
}

system_nvidia_version() {
  modinfo -F version nvidia 2>/dev/null || printf 'unknown'
}

init_state() {
  local created boot
  created=$(now_utc)
  boot=$(current_boot_id)

  jq -n \
    --arg created "$created" \
    --arg boot "$boot" \
    --arg machine "$(system_machine_id)" \
    --arg root_uuid "$(system_root_uuid)" \
    --arg fedora "$(system_fedora_version)" \
    --arg kernel "$(uname -r)" \
    --arg nvidia "$(system_nvidia_version)" \
    --argjson schema "$SCHEMA_VERSION" \
    --argjson target_boots "$TARGET_BOOTS" \
    '{
      schema_version: $schema,
      phase: "preflight",
      status: "pending",
      created_at: $created,
      updated_at: $created,
      last_error: null,
      system: {
        machine_id: $machine,
        root_uuid: $root_uuid,
        fedora: $fedora,
        kernel: $kernel,
        nvidia: $nvidia
      },
      boot_id: $boot,
      switch_boot_id: null,
      steps: {
        preflight: "pending",
        backup: "pending",
        branding: "pending",
        keyboard: "pending",
        plm_switch: "pending",
        plm_verify: "pending",
        package_removal: "pending",
        sddm_removal: "pending",
        user_cleanup: "pending",
        final_verify: "pending"
      },
      plm_verify: {
        target_boots: $target_boots,
        boots: [],
        logout_login: { done: false, boot_id: null },
        monitor_power_cycle: { done: false, boot_id: null },
        suspend_resume: { done: false, boot_id: null }
      },
      transactions: []
    }' >"$STATE"
  chmod 600 "$STATE"
}

load_state() {
  local machine root_uuid state_machine state_root tmp

  if [[ ! -f "$STATE" ]]; then
    init_state
    log "새 상태 파일을 만들었습니다: $STATE"
  fi

  if ! jq empty "$STATE" >/dev/null 2>&1; then
    warn "state.json이 손상되었습니다."
    if [[ -f "$STATE_BAK" ]] && jq empty "$STATE_BAK" >/dev/null 2>&1; then
      cp -f -- "$STATE_BAK" "$STATE"
      warn "state.json.bak에서 복구했습니다."
    else
      tmp="$STATE.corrupt.$(date +%s)"
      mv -f -- "$STATE" "$tmp"
      init_state
      warn "손상된 상태를 $tmp로 옮기고 새로 시작합니다."
    fi
  fi

  [[ "$(jq -r '.schema_version // empty' "$STATE")" == "$SCHEMA_VERSION" ]] \
    || die "지원하지 않는 state.json 버전입니다."

  machine=$(system_machine_id)
  root_uuid=$(system_root_uuid)
  state_machine=$(jq -r '.system.machine_id // empty' "$STATE")
  state_root=$(jq -r '.system.root_uuid // empty' "$STATE")

  if [[ "$state_machine" != "$machine" || "$state_root" != "$root_uuid" ]]; then
    tmp="$STATE.old.$(date +%s)"
    mv -f -- "$STATE" "$tmp"
    init_state
    warn "시스템 지문이 달라 이전 상태를 $tmp로 보관하고 새로 시작합니다."
  fi

  update_state '.boot_id = $boot' --arg boot "$(current_boot_id)"
}

state_get() {
  jq -r "$1" "$STATE"
}

update_state() {
  local filter="$1"
  shift
  local tmp ts
  ts=$(now_utc)
  tmp=$(mktemp "$DIR/.state.XXXXXX") || die "상태 임시 파일을 만들 수 없습니다."

  if ! jq -e --arg ts "$ts" "$@" "($filter) | .updated_at = \$ts" "$STATE" >"$tmp"; then
    rm -f -- "$tmp"
    die "상태 갱신에 실패했습니다."
  fi

  if ! jq -e '
      .schema_version == 1
      and (.phase | type == "string")
      and (.steps | type == "object")
      and (.plm_verify.boots | type == "array")
    ' "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    die "상태 검증에 실패했습니다."
  fi

  chmod 600 "$tmp"
  cp -p -- "$STATE" "$STATE_BAK" 2>/dev/null || true
  mv -f -- "$tmp" "$STATE"
}

set_step() {
  local step="$1" value="$2"
  update_state '.steps[$step] = $value' --arg step "$step" --arg value "$value"
}

set_phase() {
  local phase="$1"
  update_state '.phase = $phase | .status = "in_progress"' --arg phase "$phase"
}

finish_step() {
  local step="$1" next="$2"
  set_step "$step" "done"
  set_phase "$next"
}

record_transaction() {
  local id phase at
  id=$(LC_ALL=C dnf5 history list --json 2>/dev/null | jq -r 'max_by(.id).id // empty' 2>/dev/null || true)
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  phase=$(state_get '.phase')
  at=$(now_utc)
  update_state '.transactions += [{"id": $id, "phase": $phase, "at": $at}]' \
    --argjson id "$id" --arg phase "$phase" --arg at "$at"
}

# ------------------------------------------------------------
# probes
# ------------------------------------------------------------

display_manager_target() {
  systemctl show -p Id --value display-manager.service 2>/dev/null || true
}

user_display_session() {
  loginctl show-user "$USER" -p Display --value 2>/dev/null || true
}

session_value() {
  local sid="$1" key="$2"
  LC_ALL=C loginctl show-session "$sid" -p "$key" --value 2>/dev/null || true
}

os_variant() {
  . /etc/os-release
  printf '%s' "${VARIANT_ID:-unknown}"
}

count_connected_monitors() {
  local n
  n=$(kscreen-doctor -o 2>/dev/null \
    | sed -E 's/\x1B\[[0-9;]*[mK]//g' \
    | grep -c '^[[:space:]]*enabled' || true)
  printf '%s' "${n:-0}"
}

has_suspend_in_current_boot() {
  local count
  count=$(journalctl -b --no-pager -o cat 2>/dev/null | grep -c 'PM: suspend entry' || true)
  [[ "${count:-0}" -gt 0 ]]
}

# ------------------------------------------------------------
# user config / backup
# ------------------------------------------------------------

backup_user_configs() {
  local dest="$1"
  local -a paths=()
  local p

  for p in \
    ".config/cinnamon" \
    ".config/cinnamon-session" \
    ".config/cinnamon-monitors.xml" \
    ".config/nemo" \
    ".config/x-cinnamon-xdg-terminals.list" \
    ".config/autostart" \
    ".config/kxkbrc" \
    ".config/kdeglobals" \
    ".config/kwinrc" \
    ".config/kwinoutputconfig.json" \
    ".config/plasma-localerc" \
    ".config/plasma-org.kde.plasma.desktop-appletsrc" \
    ".config/plasmashellrc" \
    ".config/kdedefaults" \
    ".config/mimeapps.list" \
    ".local/share/cinnamon" \
    ".local/share/nemo"; do
    [[ -e "$HOME/$p" ]] && paths+=("$p")
  done

  if (( ${#paths[@]} > 0 )); then
    tar -czf "$dest/user-config.tar.gz" -C "$HOME" -- "${paths[@]}"
    tar -tzf "$dest/user-config.tar.gz" >/dev/null
    log "사용자 설정 백업: $dest/user-config.tar.gz"
  else
    log "백업할 사용자 설정이 없습니다."
  fi
}

backup_system_files() {
  local dest="$1"
  local p

  ensure_sudo
  for p in \
    "/etc/sddm.conf" \
    "/etc/sddm.conf.d" \
    "/etc/plasmalogin.conf" \
    "/etc/plasmalogin.conf.d" \
    "/etc/X11/xorg.conf.d/00-keyboard.conf" \
    "/etc/vconsole.conf" \
    "/usr/lib/os-release" \
    "/etc/os-release"; do
    if [[ -e "$p" ]]; then
      sudo cp -a -- "$p" "$dest/" 2>/dev/null || warn "복사 실패: $p"
    fi
  done
  sudo chown -R "$USER:" "$dest" 2>/dev/null || true
}

download_recovery_rpms() {
  local dest="$1"
  mkdir -p "$dest/rpms"
  chmod 700 "$dest/rpms"

  if LC_ALL=C dnf5 download --destdir "$dest/rpms" \
      sddm sddm-wayland-plasma \
      fedora-release-identity-cinnamon fedora-release-cinnamon \
      >/dev/null 2>&1; then
    log "복구용 RPM을 저장했습니다."
  else
    warn "복구용 RPM을 내려받지 못했습니다. 네트워크를 확인하세요."
  fi
}

# ------------------------------------------------------------
# phases
# ------------------------------------------------------------

do_preflight() {
  header "0/9 사전 점검"

  [[ $EUID -ne 0 ]] || die "이 스크립트를 root로 실행하지 마세요. 일반 사용자로 실행하세요."
  need_cmd jq flock dnf5 rpm systemctl loginctl sudo tar sha256sum findmnt kscreen-doctor nvidia-smi
  need_cmd kwriteconfig6 kreadconfig6 gsettings modinfo getent

  [[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "45" ]] || warn "Fedora 45가 아닙니다: ${VERSION_ID:-unknown}"

  rpm -q plasma-desktop plasma-login-manager sddm >/dev/null 2>&1 \
    || die "KDE Plasma, Plasma Login Manager, SDDM 패키지가 모두 필요합니다."

  nvidia-smi -L >/dev/null 2>&1 || die "NVIDIA 드라이버가 정상 동작하지 않습니다."
  modinfo -F version nvidia >/dev/null 2>&1 || die "현재 커널용 NVIDIA 모듈이 없습니다."
  getent passwd plasmalogin >/dev/null 2>&1 || die "plasmalogin 시스템 사용자가 없습니다."

  if [[ -e /dev/tty1 ]]; then
    local tty1_owner tty1_mode
    tty1_owner=$(stat -c '%U %G' /dev/tty1 2>/dev/null || true)
    tty1_mode=$(stat -c '%a' /dev/tty1 2>/dev/null || true)
    log "/dev/tty1 권한: ${tty1_mode:-?} ${tty1_owner:-?}"
  fi

  if findmnt -no OPTIONS -T "$DIR" 2>/dev/null | grep -F 'noexec' >/dev/null; then
    die "$DIR이 noexec로 마운트되어 있습니다."
  fi

  local free_kb
  free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  if [[ -z "$free_kb" || "$free_kb" -lt 5242880 ]]; then
    die "루트 파일 시스템 여유 공간이 5GiB 미만입니다."
  fi

  local sid
  sid=$(user_display_session)
  [[ -n "$sid" ]] || die "KDE 그래픽 세션에서 실행하세요. TTY에서는 --recover를 사용하세요."

  local target
  target=$(display_manager_target)
  [[ -n "$target" ]] || die "display-manager.service 대상이 없습니다."

  ensure_sudo
  log "사전 점검을 통과했습니다. 현재 로그인 관리자: $target"

  finish_step "preflight" "backup"
}

do_backup() {
  header "1/9 백업"

  local stamp dest
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_ROOT/$stamp"
  mkdir -p "$dest"
  chmod 700 "$dest" "$BACKUP_ROOT"

  rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort >"$dest/rpms-before.txt"
  dnf5 history list --json >"$dest/dnf-history-before.json" 2>/dev/null || true
  loginctl list-sessions >"$dest/loginctl.txt" 2>/dev/null || true
  kscreen-doctor -o >"$dest/kscreen.txt" 2>/dev/null || true
  findmnt >"$dest/findmnt.txt" 2>/dev/null || true
  lsblk >"$dest/lsblk.txt" 2>/dev/null || true

  backup_user_configs "$dest"
  backup_system_files "$dest"
  download_recovery_rpms "$dest"

  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$dest"
      find . -type f ! -name MANIFEST.sha256 -print0 \
        | sort -z \
        | xargs -0 sha256sum >MANIFEST.sha256
    )
  fi

  log "백업 위치: $dest"
  finish_step "backup" "branding"
}

do_branding() {
  header "2/9 Fedora KDE 브랜딩"

  local variant old new version dry rc out
  variant=$(os_variant)

  if [[ "$variant" == "kde" ]]; then
    log "이미 KDE Plasma Desktop Edition입니다."
    finish_step "branding" "keyboard"
    return 0
  fi

  rpm -q sddm >/dev/null 2>&1 || die "SDDM이 설치되어 있지 않습니다. 브랜딩 전에 설치하세요."

  version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' fedora-release-common 2>/dev/null || true)
  [[ -n "$version" ]] || die "fedora-release-common 버전을 확인할 수 없습니다."

  old="fedora-release-identity-cinnamon-${version}.noarch"
  new="fedora-release-identity-kde-desktop-${version}.noarch"

  if ! rpm -q "$old" >/dev/null 2>&1; then
    if rpm -q "$new" >/dev/null 2>&1; then
      log "이미 KDE identity 패키지가 설치되어 있습니다."
      finish_step "branding" "keyboard"
      return 0
    fi
    die "교체할 Cinnamon identity 패키지를 찾을 수 없습니다: $old"
  fi

  if ! LC_ALL=C dnf5 repoquery --available --latest-limit=1 \
      --qf '%{name}-%{version}-%{release}.%{arch}\n' \
      fedora-release-identity-kde-desktop 2>/dev/null \
      | grep -Fx "$new" >/dev/null; then
    die "저장소에 $new가 없습니다. 먼저 dnf 업데이트를 확인하세요."
  fi

  printf '\n교체 계획:\n  제거: %s\n  설치: %s\n\n' "$old" "$new"

  set +e
  out=$(LC_ALL=C dnf5 swap --from-repo=updates --assumeno "$old" "$new" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"

  if [[ $rc -ne 0 && $rc -ne 1 ]]; then
    die "브랜딩 모의 실행이 실패했습니다."
  fi
  if printf '%s\n' "$out" | grep -Eq '^[[:space:]]+sddm[[:space:]]'; then
    die "브랜딩 계획에 SDDM 제거가 포함되어 있습니다. 중단합니다."
  fi

  confirm "위 브랜딩 교체를 적용할까요?" || { log "사용자가 브랜딩 교체를 취소했습니다."; exit 0; }

  ensure_sudo
  sudo env LC_ALL=C dnf5 -y swap --from-repo=updates "$old" "$new"
  record_transaction

  rpm -q "$new" >/dev/null 2>&1 || die "KDE identity 패키지 설치를 확인하지 못했습니다."
  rpm -q sddm >/dev/null 2>&1 || die "브랜딩 후 SDDM이 사라졌습니다. 즉시 복구하세요."

  variant=$(os_variant)
  [[ "$variant" == "kde" ]] || die "os-release가 KDE로 바뀌지 않았습니다."

  log "브랜딩이 KDE Plasma Desktop Edition으로 바뀌었습니다."
  finish_step "branding" "keyboard"
}

do_keyboard() {
  header "3/9 키보드와 Caps Lock"

  local sid
  sid=$(user_display_session)
  [[ -n "$sid" ]] || die "키보드 설정은 KDE 그래픽 세션에서만 진행할 수 있습니다."

  if [[ -f "$HOME/.config/kxkbrc" ]]; then
    cp -a -- "$HOME/.config/kxkbrc" "$BACKUP_ROOT/kxkbrc.before-$(date +%s)"
  fi

  kwriteconfig6 --file kxkbrc --group Layout --key Use true
  kwriteconfig6 --file kxkbrc --group Layout --key LayoutList kr
  kwriteconfig6 --file kxkbrc --group Layout --key VariantList kr104
  kwriteconfig6 --file kxkbrc --group Layout --key Options "korean:ralt_hangul,caps:none"

  if ! gsettings set org.freedesktop.ibus.engine.hangul switch-keys 'Hangul,Caps_Lock'; then
    warn "IBus Caps Lock 설정을 적용하지 못했습니다. KDE 입력 설정에서 직접 확인하세요."
  fi

  local layout
  layout=$(kreadconfig6 --file kxkbrc --group Layout --key LayoutList 2>/dev/null || true)
  [[ "$layout" == *kr* ]] || die "kxkbrc에 한국어 레이아웃이 기록되지 않았습니다."

  if [[ -f "$HOME/.config/autostart/caps-hangul.desktop" ]]; then
    mv -f -- "$HOME/.config/autostart/caps-hangul.desktop" \
      "$HOME/.config/autostart/caps-hangul.desktop.disabled"
    log "xmodmap 기반 Caps Lock 자동 시작을 비활성화했습니다."
  fi

  log "키보드 설정을 적용했습니다. 로그아웃 후 다시 로그인하면 반영됩니다."
  finish_step "keyboard" "plm_switch"
}

do_plm_switch() {
  header "4/9 Plasma Login Manager 전환"

  confirm "SDDM을 끄고 Plasma Login Manager로 전환할까요? 재부팅이 필요합니다." \
    || { log "사용자가 로그인 관리자 전환을 취소했습니다."; exit 0; }

  ensure_sudo

  run_root systemctl disable sddm 2>/dev/null || true
  run_root systemctl enable --force plasmalogin.service

  local target
  target=$(display_manager_target)
  [[ "$target" == "plasmalogin.service" ]] \
    || die "display-manager가 plasmalogin.service를 가리키지 않습니다: $target"

  update_state '.steps.plm_switch = "done" | .switch_boot_id = $boot | .phase = "plm_verify" | .status = "awaiting_reboot"' \
    --arg boot "$(current_boot_id)"

  cat <<'EOF'

전환이 완료되었습니다. 아직 재부팅하지 마세요.

다음 순서:
  1. 두 모니터의 전원이 켜져 있는지 확인
  2. 터미널에서 sudo reboot 실행
  3. 재부팅 후 같은 스크립트를 다시 실행

  sudo reboot
  ~/<workdir>/SwitchToPlasma.sh

복구가 필요하면 TTY에서:
  Ctrl+Alt+F3
  ~/<workdir>/SwitchToPlasma.sh --recover

SDDM은 아직 제거되지 않았습니다.
EOF
  exit 0
}

do_plm_verify() {
  header "5/9 Plasma Login Manager 검증"

  local boot switch_boot sid service type desktop active dual exists boots dual_boots
  boot=$(current_boot_id)
  switch_boot=$(state_get '.switch_boot_id // empty')

  if [[ -n "$switch_boot" && "$boot" == "$switch_boot" ]]; then
    printf '아직 재부팅하지 않았습니다. 재부팅 후 다시 실행하세요.\n'
    exit 0
  fi

  sid=$(user_display_session)
  if [[ -z "$sid" ]]; then
    printf '그래픽 세션이 없습니다. Ctrl+Alt+F3에서 --recover를 실행하세요.\n'
    exit 1
  fi

  service=$(session_value "$sid" Service)
  type=$(session_value "$sid" Type)
  desktop=$(session_value "$sid" Desktop)
  active=$(session_value "$sid" Active)

  printf '부팅 ID: %s\n세션: %s\nService: %s\nType: %s\nDesktop: %s\nActive: %s\n' \
    "$boot" "$sid" "$service" "$type" "$desktop" "$active"

  if [[ "$service" != "plasmalogin" || "$type" != "wayland" || "$active" != "yes" ]]; then
    printf '\nPlasma Login Manager 세션이 확인되지 않았습니다.\n'
    printf 'SDDM으로 복구하려면 TTY에서 --recover를 실행하세요.\n'
    exit 1
  fi

  if [[ "$desktop" != "KDE" && "$desktop" != "plasma" ]]; then
    printf '\nKDE 세션이 아닙니다: %s\n' "$desktop"
    exit 1
  fi

  dual=0
  if [[ "$(count_connected_monitors)" -ge 2 ]]; then
    dual=1
  fi

  exists=$(jq --arg id "$boot" '[.plm_verify.boots[] | select(.id == $id)] | length' "$STATE")
  if [[ "$exists" == "0" ]]; then
    update_state '.plm_verify.boots += [{"id": $id, "dual": ($dual == 1), "at": $at}]' \
      --arg id "$boot" --argjson dual "$dual" --arg at "$(now_utc)"
  fi

  boots=$(jq -r '.plm_verify.boots | length' "$STATE")
  dual_boots=$(jq -r '[.plm_verify.boots[] | select(.dual == true)] | length' "$STATE")
  printf '\n확인된 부팅: %s/%s (두 모니터 부팅: %s)\n' "$boots" "$TARGET_BOOTS" "$dual_boots"

  if [[ "$(state_get '.plm_verify.logout_login.done')" != "true" ]]; then
    if confirm "이번 또는 이전 부팅에서 로그아웃 후 다시 로그인했습니까?"; then
      update_state '.plm_verify.logout_login = {"done": true, "boot_id": $boot}' --arg boot "$boot"
    else
      printf '로그아웃 후 다시 로그인하고 이 스크립트를 다시 실행하세요.\n'
      exit 0
    fi
  fi

  if [[ "$(state_get '.plm_verify.monitor_power_cycle.done')" != "true" ]]; then
    if confirm "모니터 전원을 껐다 켜 보셨습니까?"; then
      update_state '.plm_verify.monitor_power_cycle = {"done": true, "boot_id": $boot}' --arg boot "$boot"
    else
      printf '모니터 전원을 껐다 켠 뒤 이 스크립트를 다시 실행하세요.\n'
      exit 0
    fi
  fi

  if [[ "$(state_get '.plm_verify.suspend_resume.done')" != "true" ]]; then
    if has_suspend_in_current_boot; then
      update_state '.plm_verify.suspend_resume = {"done": true, "boot_id": $boot, "skipped": false}' --arg boot "$boot"
    else
      if confirm "지금 절전 후 복귀 테스트를 하시겠습니까?"; then
        printf '절전 후 복귀한 다음 이 스크립트를 다시 실행하세요.\n'
        exit 0
      fi
      if confirm "절전 테스트를 건너뛰고 계속할까요? (권장하지 않음)"; then
        update_state '.plm_verify.suspend_resume = {"done": true, "boot_id": $boot, "skipped": true}' --arg boot "$boot"
        warn "절전 테스트를 건너뛰었습니다. 최종 확인에서 별도로 점검하세요."
      else
        printf '절전 테스트가 아직 완료되지 않았습니다. 완료 후 다시 실행하세요.\n'
        exit 0
      fi
    fi
  fi

  if (( boots >= TARGET_BOOTS )) \
      && (( dual_boots >= 2 )) \
      && [[ "$(state_get '.plm_verify.logout_login.done')" == "true" ]] \
      && [[ "$(state_get '.plm_verify.monitor_power_cycle.done')" == "true" ]] \
      && [[ "$(state_get '.plm_verify.suspend_resume.done')" == "true" ]]; then
    log "PLM 검증을 통과했습니다."
    finish_step "plm_verify" "package_removal"
  else
    printf '\n아직 통과하지 못했습니다.\n'
    printf '필요: 서로 다른 부팅 %s회, 두 모니터 부팅 2회, 로그아웃/로그인, 모니터 전원, 절전.\n' "$TARGET_BOOTS"
    printf '다음 부팅 후 같은 스크립트를 다시 실행하세요.\n'
    exit 0
  fi
}

remove_packages() {
  local label="$1"
  shift
  local -a installed=()
  local p out rc

  for p in "$@"; do
    rpm -q "$p" >/dev/null 2>&1 && installed+=("$p")
  done

  if (( ${#installed[@]} == 0 )); then
    log "$label: 제거할 패키지가 없습니다."
    return 0
  fi

  printf '\n%s: %s개 제거 예정\n' "$label" "${#installed[@]}"
  printf '  %s\n' "${installed[@]}"

  for p in "${installed[@]}"; do
    case "$p" in
      plasma-*|plasmalogin*|kwin*|systemd|NetworkManager|glibc|bash|sudo|dnf5|rpm)
        die "$label 제거 목록에 보호 패키지가 있습니다: $p"
        ;;
    esac
  done

  ensure_sudo
  set +e
  out=$(LC_ALL=C dnf5 remove --no-autoremove --assumeno "${installed[@]}" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"

  if [[ $rc -ne 0 && $rc -ne 1 ]]; then
    die "$label 모의 제거가 실패했습니다."
  fi
  if printf '%s\n' "$out" | grep -Eq '^[[:space:]]+(plasma|kwin|systemd|nvidia|NetworkManager|glibc|bash|sudo|dnf5|rpm)[-[:space:]]'; then
    die "$label 제거 계획에 보호 패키지가 포함되어 있습니다. 중단합니다."
  fi

  confirm "$label 패키지를 제거할까요?" || { log "사용자가 $label 제거를 취소했습니다."; return 1; }

  sudo env LC_ALL=C dnf5 -y remove --no-autoremove "${installed[@]}"
  record_transaction

  for p in plasma-login-manager plasma-desktop kwin systemd NetworkManager; do
    rpm -q "$p" >/dev/null 2>&1 || die "보호 패키지가 사라졌습니다: $p"
  done

  log "$label 제거를 완료했습니다."
}

do_package_removal() {
  header "6/9 Cinnamon과 중복 앱 제거"

  local target sid boots dual_boots
  [[ "$(state_get '.steps.plm_verify')" == "done" ]] \
    || die "PLM 검증을 통과하지 않았습니다. 패키지를 제거하지 않습니다."
  boots=$(jq -r '.plm_verify.boots | length' "$STATE")
  dual_boots=$(jq -r '[.plm_verify.boots[] | select(.dual == true)] | length' "$STATE")
  (( boots >= TARGET_BOOTS )) || die "검증된 부팅이 부족합니다: ${boots}/${TARGET_BOOTS}"
  (( dual_boots >= 2 )) || die "두 모니터 부팅 검증이 부족합니다: ${dual_boots}/2"
  [[ "$(state_get '.plm_verify.logout_login.done')" == "true" ]] \
    || die "로그아웃/로그인 검증이 없습니다."
  [[ "$(state_get '.plm_verify.monitor_power_cycle.done')" == "true" ]] \
    || die "모니터 전원 검증이 없습니다."
  [[ "$(state_get '.plm_verify.suspend_resume.done')" == "true" ]] \
    || die "절전/복귀 검증이 없습니다."

  target=$(display_manager_target)
  [[ "$target" == "plasmalogin.service" ]] || die "PLM이 기본 로그인 관리자가 아닙니다."

  sid=$(user_display_session)
  if [[ -n "$sid" ]]; then
    [[ "$(session_value "$sid" Service)" == "plasmalogin" ]] \
      || die "현재 세션이 PLM이 아닙니다. 재부팅 후 다시 실행하세요."
  fi

  local -a cinnamon_pkgs=(
    cinnamon cinnamon-calendar-server cinnamon-control-center
    cinnamon-control-center-filesystem cinnamon-desktop cinnamon-menus
    cinnamon-session cinnamon-settings-daemon cinnamon-themes
    cinnamon-translations cjs nemo nemo-extensions nemo-fileroller
    nemo-image-converter nemo-python nemo-search-helpers muffin
    mint-themes mint-themes-gtk3 mint-themes-gtk4 mint-x-icons mint-y-icons
    mint-y-theme mintlocale mintlocale-set-default-locale
    folder-color-switcher-nemo xapps xapp-symbolic-icons python3-xapp
    python3-xapps-overrides xdg-desktop-portal-xapp xed xreader eom metacity
  )

  local -a extra_pkgs=(
    shotwell simple-scan mpv yt-dlp transmission transmission-gtk
    transmission-common pidgin zoitechat thunderbird baobab
    gnome-calculator gnome-system-monitor gnome-disk-utility gnome-terminal
    blueman blueman-nemo xfburn xawtv paper-icon-theme
    qt6-qtwayland-adwaita-decoration
    gnome-software gnome-software-fedora-langpacks gucharmap file-roller yelp
    system-config-printer xdg-user-dirs-gtk pinentry-gnome3
  )

  if ! remove_packages "Cinnamon" "${cinnamon_pkgs[@]}"; then
    exit 0
  fi
  if ! remove_packages "중복 앱" "${extra_pkgs[@]}"; then
    exit 0
  fi

  finish_step "package_removal" "sddm_removal"
}

do_sddm_removal() {
  header "7/9 SDDM과 보조 로그인 관리자 제거"

  [[ "$(state_get '.steps.plm_verify')" == "done" ]] \
    || die "PLM 검증을 통과하지 않았습니다. SDDM을 제거하지 않습니다."
  [[ "$(state_get '.steps.package_removal')" == "done" ]] \
    || die "패키지 제거 단계가 끝나지 않았습니다."

  local kit="$BACKUP_ROOT/rpms"
  mkdir -p "$kit"
  chmod 700 "$kit"

  if LC_ALL=C dnf5 download --destdir "$kit" sddm sddm-wayland-plasma >/dev/null 2>&1; then
    log "SDDM 복구 RPM을 준비했습니다: $kit"
  else
    warn "SDDM 복구 RPM을 준비하지 못했습니다. 네트워크를 확인하세요."
  fi

  if ! remove_packages "SDDM" sddm sddm-wayland-plasma; then
    exit 0
  fi

  if ! remove_packages "lightdm" lightdm lightdm-gobject lightdm-settings \
      slick-greeter slick-greeter-cinnamon; then
    exit 0
  fi

  local target
  target=$(display_manager_target)
  [[ "$target" == "plasmalogin.service" ]] \
    || die "SDDM 제거 후 display-manager 대상이 잘못되었습니다: $target"

  finish_step "sddm_removal" "user_cleanup"
}

do_user_cleanup() {
  header "8/9 Cinnamon 사용자 설정 정리"

  local stamp dest p
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_ROOT/user-cleanup-$stamp"
  mkdir -p "$dest"
  chmod 700 "$dest"

  for p in \
    ".config/cinnamon" \
    ".config/cinnamon-session" \
    ".config/cinnamon-monitors.xml" \
    ".config/nemo" \
    ".config/x-cinnamon-xdg-terminals.list" \
    ".local/share/cinnamon" \
    ".local/share/nemo" \
    ".config/autostart/caps-hangul.desktop.disabled"; do
    if [[ -e "$HOME/$p" ]]; then
      mv -- "$HOME/$p" "$dest/" || warn "이동 실패: $p"
    fi
  done

  rm -f -- "$HOME/.config/menus/cinnamon-applications-merged" 2>/dev/null || true

  if command -v dconf >/dev/null 2>&1; then
    dconf reset -f /org/cinnamon/ 2>/dev/null || true
    dconf reset -f /org/nemo/ 2>/dev/null || true
  fi

  printf '%s\n' 'org.kde.konsole.desktop' >"$HOME/.config/xdg-terminals.list"
  log "Cinnamon 사용자 설정을 $dest로 옮겼습니다."
  finish_step "user_cleanup" "final_verify"
}

do_final_verify() {
  header "9/9 최종 확인"

  local failed=0 variant target sid service
  variant=$(os_variant)
  target=$(display_manager_target)
  sid=$(user_display_session)

  [[ "$variant" == "kde" ]] || { warn "os-release가 KDE가 아닙니다: $variant"; failed=1; }
  [[ "$target" == "plasmalogin.service" ]] || { warn "display-manager 대상이 다릅니다: $target"; failed=1; }

  if [[ -n "$sid" ]]; then
    service=$(session_value "$sid" Service)
    [[ "$service" == "plasmalogin" ]] || { warn "현재 세션 Service가 다릅니다: $service"; failed=1; }
  fi

  rpm -q plasma-desktop plasma-login-manager plasma-workspace >/dev/null 2>&1 \
    || { warn "핵심 KDE 패키지가 없습니다."; failed=1; }

  local p
  for p in cinnamon nemo lightdm slick-greeter sddm sddm-wayland-plasma; do
    if rpm -q "$p" >/dev/null 2>&1; then
      warn "아직 남아 있는 패키지: $p"
      failed=1
    fi
  done

  nvidia-smi >/dev/null 2>&1 || { warn "NVIDIA 드라이버가 정상이 아닙니다."; failed=1; }

  if [[ "$(count_connected_monitors)" -lt 2 ]]; then
    warn "모니터가 2개 감지되지 않았습니다."
  fi

  if [[ "$(kreadconfig6 --file kxkbrc --group Layout --key LayoutList 2>/dev/null || true)" != *kr* ]]; then
    warn "한국어 키보드 레이아웃이 확인되지 않았습니다."
    failed=1
  fi

  if (( failed != 0 )); then
    printf '\n최종 확인에서 문제가 발견되었습니다. 위 경고를 확인하세요.\n'
    exit 1
  fi

  set_step "final_verify" "done"
  update_state '.phase = "done" | .status = "done"'
  cat <<'EOF'

완료되었습니다.

- Fedora KDE Plasma Desktop Edition
- Plasma Login Manager가 기본 로그인 관리자
- Cinnamon, SDDM, lightdm 제거
- NVIDIA 드라이버와 Plasma Wayland 유지

한 번 더 재부팅해서 로그인 화면과 한글 입력을 확인하세요.
복구가 필요하면:
  ~/<workdir>/SwitchToPlasma.sh --recover
EOF
}

# ------------------------------------------------------------
# status / dry run / recover
# ------------------------------------------------------------

show_status() {
  if [[ ! -f "$STATE" ]]; then
    printf 'state.json이 아직 없습니다. 스크립트를 한 번 실행하면 생성됩니다.\n'
    return 0
  fi

  if ! jq empty "$STATE" >/dev/null 2>&1; then
    printf 'state.json을 읽을 수 없습니다. --recover로 복구하세요.\n'
    return 1
  fi

  printf '상태 파일: %s\n' "$STATE"
  jq -r '
    "단계: \(.phase) (\(.status))",
    "갱신: \(.updated_at)",
    "브랜딩: \(.steps.branding)",
    "PLM 전환: \(.steps.plm_switch)",
    "PLM 검증: \(.steps.plm_verify)  부팅 \(.plm_verify.boots|length)/\(.plm_verify.target_boots)",
    "  로그아웃/로그인: \(.plm_verify.logout_login.done)",
    "  모니터 전원: \(.plm_verify.monitor_power_cycle.done)",
    "  절전: \(.plm_verify.suspend_resume.done)",
    "패키지 제거: \(.steps.package_removal)",
    "SDDM 제거: \(.steps.sddm_removal)",
    "최종 확인: \(.steps.final_verify)"
  ' "$STATE"

  printf '\n현재 시스템:\n'
  printf '  os-release: %s\n' "$(os_variant)"
  printf '  display-manager: %s\n' "$(display_manager_target)"
  local sid
  sid=$(user_display_session)
  if [[ -n "$sid" ]]; then
    printf '  세션: %s\n' "$sid"
    printf '  Service: %s\n' "$(session_value "$sid" Service)"
    printf '  Desktop: %s\n' "$(session_value "$sid" Desktop)"
    printf '  Type: %s\n' "$(session_value "$sid" Type)"
  else
    printf '  그래픽 세션 없음\n'
  fi
  printf '  모니터: %s개\n' "$(count_connected_monitors)"
  printf '  NVIDIA: %s\n' "$(system_nvidia_version)"
}

show_plan() {
  cat <<'EOF'
SwitchToPlasma 예정 작업

0. 사전 점검
1. 패키지 목록, 사용자 설정, 시스템 설정, 복구 RPM 백업
2. fedora-release-identity를 KDE Desktop Edition으로 교체
3. KDE 키보드와 Caps Lock을 Wayland 방식으로 설정
4. SDDM 비활성화, Plasma Login Manager 활성화 후 재부팅 안내
5. 서로 다른 부팅 3회, 로그아웃/로그인, 모니터 전원, 절전 검증
6. Cinnamon과 중복 앱 제거
7. SDDM과 lightdm 제거
8. Cinnamon 사용자 설정을 백업 폴더로 이동
9. 최종 확인

이 스크립트는 재부팅을 직접 수행하지 않습니다.
EOF
  show_status
}

recover_menu() {
  need_tty "$@"
  acquire_lock
  load_state

  while true; do
    cat <<'EOF'

복구 메뉴
  1) 상태 보기
  2) 현재 단계 계속
  3) SDDM으로 되돌리기
  4) 최근 로그 보기
  5) 종료
EOF
    printf '선택: '
    local choice
    read -r choice </dev/tty || exit 0

    case "$choice" in
      1) show_status ;;
      2) return 0 ;;
      3)
        restore_sddm
        ;;
      4)
        local latest
        latest=$(find "$LOG_DIR" -maxdepth 1 -type f -name 'run-*.log' -printf '%T@ %p\n' 2>/dev/null \
          | sort -n | tail -1 | awk '{print $2}')
        if [[ -n "$latest" ]]; then
          tail -n 100 -- "$latest"
        else
          printf '로그가 없습니다.\n'
        fi
        ;;
      5|q|Q) exit 0 ;;
      *) printf '1-5 중에서 선택하세요.\n' ;;
    esac
  done
}

restore_sddm() {
  local sid
  sid=$(user_display_session)
  if [[ -n "$sid" && "$(session_value "$sid" Service)" == "plasmalogin" ]]; then
    die "현재 PLM 세션에서 SDDM을 시작할 수 없습니다. Ctrl+Alt+F3의 TTY에서 실행하세요."
  fi

  ensure_sudo

  if ! rpm -q sddm >/dev/null 2>&1; then
    printf 'SDDM이 없습니다. 복구 RPM 또는 저장소에서 설치합니다.\n'
    if compgen -G "$BACKUP_ROOT/rpms/sddm-*.rpm" >/dev/null; then
      sudo dnf5 install -y --disablerepo='*' "$BACKUP_ROOT"/rpms/sddm-*.rpm \
        || die "복구 RPM 설치에 실패했습니다."
    else
      sudo dnf5 install -y sddm sddm-wayland-plasma \
        || die "SDDM 설치에 실패했습니다."
    fi
  fi

  sudo systemctl stop plasmalogin 2>/dev/null || true
  sudo systemctl disable plasmalogin 2>/dev/null || true
  sudo systemctl enable --force sddm.service
  sudo systemctl start sddm

  local target
  target=$(display_manager_target)
  [[ "$target" == "sddm.service" ]] || die "SDDM 복구 후 display-manager 대상이 다릅니다: $target"

  update_state '.status = "recovered_to_sddm"' 2>/dev/null || true
  printf 'SDDM으로 복구했습니다. 재부팅 후 로그인하세요.\n'
}

# ------------------------------------------------------------
# lock and run
# ------------------------------------------------------------

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n -E 75 9; then
    printf '이미 다른 인스턴스가 실행 중입니다.\n' >&2
    printf '잠금 파일: %s\n' "$LOCK_FILE" >&2
    exit 75
  fi
}

run_main() {
  need_tty "$@"
  acquire_lock

  mkdir -p "$LOG_DIR" "$BACKUP_ROOT"
  chmod 700 "$LOG_DIR" "$BACKUP_ROOT"
  LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG"
  chmod 600 "$LOG"

  load_state

  local i phase
  for i in $(seq 1 30); do
    phase=$(state_get '.phase')
    case "$phase" in
      preflight) do_preflight ;;
      backup) do_backup ;;
      branding) do_branding ;;
      keyboard) do_keyboard ;;
      plm_switch) do_plm_switch ;;
      plm_verify) do_plm_verify ;;
      package_removal) do_package_removal ;;
      sddm_removal) do_sddm_removal ;;
      user_cleanup) do_user_cleanup ;;
      final_verify) do_final_verify ;;
      done)
        printf '이미 완료되었습니다. 상태를 확인하려면 --status를 사용하세요.\n'
        exit 0
        ;;
      *)
        die "알 수 없는 단계입니다: $phase"
        ;;
    esac
  done

  die "단계 전환이 너무 많습니다. 상태 파일을 확인하세요."
}

usage() {
  cat <<EOF
사용법:
  $SELF              진행 또는 이어서 실행
  $SELF --status     현재 상태 보기
  $SELF --dry-run    예정 작업 보기
  $SELF --recover    TTY 복구 메뉴
EOF
}

case "${1:-}" in
  --status|status)
    show_status
    ;;
  --dry-run|dry-run)
    show_plan
    ;;
  --recover|recover)
    recover_menu
    exec 9>&-
    run_main
    ;;
  -h|--help|help)
    usage
    ;;
  "")
    run_main
    ;;
  *)
    usage
    exit 2
    ;;
esac
