# resumable-task-script

## 출처

- 원본 컴퓨터: Desktop(with RTX3060)
- OS: Fedora Linux 45 (KDE Plasma Desktop Edition)
- OpenCode: v2.2.6
- 테스트 날짜: 2026-11-22
- 원본 활성 위치: `~/.config/opencode/skills/resumable-task-script`

이 폴더는 참고용 복사본이다. 이 컴퓨터에서 실제로 사용하는 스킬은 전역 `~/.config/opencode/skills`에 있다. 저장소를 전역 skills 소스로 등록하지 않는다.

## 목적

재부팅, 여러 세션, 장시간 작업, 중간 실패가 있는 작업을 다음 구조로 구현한다.

- 사용자 진입점은 스크립트 하나
- 상태 기록은 JSON 하나
- 재실행 시 이어서 진행
- 파괴적 작업 전 검증 게이트
- 자동 검사와 사용자 확인을 결합한 기능 검사
- TTY 복구 경로

## 범용 부분

- 단계 머신과 `verify`/`apply` 분리
- JSON 상태, 원자적 갱신, `flock`
- `boot_id` 기반 재개와 중복 방지
- `--status`, `--dry-run`, `--recover`
- 검증 게이트와 기능 검사
- 실패 복구와 롤백 설계

## 컴퓨터 특수 부분

- Fedora Linux 45
- KDE Plasma 6.8.3, Wayland
- Plasma Login Manager와 SDDM
- NVIDIA RTX 3060, 드라이버 620.70.06
- 듀얼 모니터 1920x1080 144Hz + 1920x1080 60Hz
- Secure Boot와 akmod 서명

## 검증된 사례

`examples/fedora-cinnamon-to-kde/`에 Fedora Cinnamon에서 KDE Plasma로 전환한 실제 스크립트와 상태 예시가 있다.

이 예시는 당시 환경의 스냅샷이다. 패키지 이름과 버전은 시스템마다 다시 확인해야 한다.

## 민감 정보 삭제 내역

- 실제 machine ID, root UUID, boot ID를 예제 값으로 치환
- 사용자 홈 디렉터리 절대 경로를 `~/<workdir>` 형태로 일반화
- 계정 이름과 호스트명 제거
- 예제 상태의 트랜잭션 ID와 시간은 예시 값으로 정리

## 알려진 제한

- Fedora 45 기준이므로 다른 배포판이나 버전에서는 명령을 재검증해야 한다.
- 전체 예제 스크립트를 그대로 실행하면 안 된다. 구조와 교훈을 참고한다.
- 이 저장소의 스크립트는 직접 실행하지 않는다.

## 마지막 검토

- 2026-11-22
