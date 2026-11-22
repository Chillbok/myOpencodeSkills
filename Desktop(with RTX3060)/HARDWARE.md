# Computer Hardware

## Identity

- Folder name: Desktop(with RTX3060)
- Computer type: Desktop
- Purpose: 데스크톱 개발, 게임, 로컬 AI 실험
- Notes: NVIDIA RTX 3060 기반 데스크톱

## OS

- OS: Fedora Linux
- Version: 45 (KDE Plasma Desktop Edition)
- Kernel: 7.3.4-300.fc45.x86_64
- Desktop: KDE Plasma 6.8.3, Wayland
- OpenCode version: v2.2.6

## CPU

- Model: AMD Ryzen 5 9600X
- Cores / threads: 6 cores / 12 threads
- Notes: Zen 5, 최대 부스트 약 5.5GHz

## GPU

- Model: NVIDIA GeForce RTX 3060 (GA106)
- VRAM: 12GB
- Driver: NVIDIA 620.70.06, open kernel modules
- Notes: Secure Boot 환경에서 akmod 서명 사용, nvidia_drm modeset 활성화

## Memory

- Total: 16GB (시스템에서 약 15GiB로 표시)
- Notes: zram 스왑 8GB 사용, 하이버네이트 불가

## Storage

- System disk: NVMe 약 466GB, btrfs, root와 home 서브볼륨
- Data disks: NVMe 약 466GB NTFS, HDD 약 1TB, SSD 약 112GB
- Free space: 루트 파일 시스템 약 125GB 여유
- Notes: 홈 디렉터리에 대용량 게임 라이브러리 존재

## Motherboard and firmware

- Model: Gigabyte B650M K
- Firmware: FB8 (2025-12)
- Secure Boot: Enabled
- Notes: UEFI

## Displays

- Monitor 1: DisplayPort, 1920x1080, 144Hz
- Monitor 2: HDMI, 1920x1080, 60Hz
- Resolution / refresh: 듀얼 모니터
- Notes: NVIDIA Wayland 환경에서 다중 모니터 전환 시 주의 필요

## Peripherals

- Keyboard: 확인 필요
- Mouse: 확인 필요
- Audio: 확인 필요
- Printer / scanner: 확인 필요
- Notes: 스캐너는 현재 감지되지 않음

## Network

- Connection type: 유선 연결
- Notes: 원격 접속 및 메시 네트워크 도구 사용

## Local AI capability

- Suitable workloads: 12GB VRAM 이내의 소형 언어 모델, 음성 인식, 이미지 생성, 로컬 추론
- Limits: 16GB 시스템 RAM, 12GB VRAM, 하이버네이트 불가
- Notes: CUDA 및 Vulkan 사용 가능, 대형 모델의 장시간 학습에는 부적합

## Security

- Secure Boot: Enabled
- Disk encryption: 확인 필요
- Notes: NVIDIA 모듈은 akmod로 서명됨

## Constraints and special notes

- NVIDIA Wayland 환경이므로 스킬 이식 시 그래픽 관련 동작을 재검증해야 한다.
- 다중 모니터와 144Hz 주사율을 사용한다.
- 하이버네이트는 사용할 수 없고 절전 복귀만 가능하다.
- Fedora 45와 KDE Plasma 6.8 기준으로 작성되었다.
