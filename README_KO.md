# Jamak Trans (자막 번역) — macOS SRT 자막 번역기

[English](README.md) · 한국어

macOS에 내장된 온디바이스 번역(Translation 프레임워크)으로 SRT 자막을 대상 언어로 번역하는 네이티브 앱입니다. 자막 내용은 외부 서버로 보내지 않습니다.

## 설치

터미널에 한 줄:

```sh
curl -fsSL https://raw.githubusercontent.com/ziozzang/jamak-trans/main/install.sh | sh
```

- 최신 릴리스를 받아 `SHA256SUMS`로 검증한 뒤 `/Applications/JamakTrans.app`에 설치합니다.
- 앱은 공증 없이 ad-hoc 서명만 되어 있습니다. `curl`로 받은 파일에는 격리 표시가 붙지 않아 Gatekeeper 경고 없이 열립니다. 이후 업데이트는 앱의 자동 업데이트가 합니다.
- [Releases](https://github.com/ziozzang/jamak-trans/releases)에서 브라우저로 zip을 받으면 "손상되었거나 확인되지 않은 개발자"라며 막힙니다. 그때는 다음 명령을 한 번 실행하세요.

```sh
xattr -dr com.apple.quarantine /Applications/JamakTrans.app
```

## 빌드

```sh
./build.sh          # → build/JamakTrans.app (arm64 + x86_64 유니버설, ad-hoc 서명), 버전은 VERSION 파일
./build.sh debug
```

- 요구 사항: macOS 26 이상, Swift 6 (Command Line Tools만 있어도 됨)
- SwiftPM 없이 `swiftc`로 직접 빌드합니다. `Package.swift`는 Xcode에서 열어 볼 때 쓰세요.

## 사용법

- 창이나 Dock 아이콘에 `.srt` 파일 또는 폴더를 끌어다 놓습니다. 폴더는 하위 폴더까지 모두 찾습니다.
- 파일마다 원본 언어를 감지한 뒤(NaturalLanguage), 파일 전체를 그 언어에서 대상 언어로 번역합니다.
- 건너뛰는 경우:
  - 원본이 이미 대상 언어일 때
  - 문장의 30% 이상이 이미 대상 언어일 때(이중 언어 자막)
  - 번역 파일(`이름.ko.srt`)이 이미 있을 때(덮어쓰기 옵션으로 끌 수 있음)
  - 여러 원본이 같은 출력 파일을 만들 때(`movie.en.srt`, `movie.ja.srt` → `movie.ko.srt`)
- 동시 작업(1–8개), 대기열, 일시정지/중지/다시 시도, 전체·파일별 진행률(문장 n/m), 처리 속도와 남은 시간을 지원합니다.
- 설치되지 않은 언어 모델은 시스템 다운로드 창을 한 번에 하나씩 띄워 받습니다.

## 출력 옵션

| 옵션 | 선택지 |
|---|---|
| 내용 | 번역문만 / 번역문 + 원문(원문은 아래 줄에 회색 `#a0a0a0`) |
| 형식 | SRT(UTF-8) / SMI(UTF-8 + BOM, `<SYNC>` 기반, 번역문 위·원문 아래) |
| 파일 이름 | 새 파일 `이름.ko.srt`(원본 유지) / 원본 이름 사용: `foo.srt`에 번역을 쓰고 원본은 `foo.srt.org`로 바꿈 |

- 원본 이름 사용 + SMI이면 `foo.smi`를 만들고, 원본은 역시 `foo.srt.org`로 바꿉니다.
- 번역 결과를 임시 파일에 먼저 쓴 뒤에 원본 이름을 바꿉니다. 그래서 중간에 실패해도 원본은 남습니다.
- `foo.srt.org`가 이미 있으면 그 파일은 건너뜁니다. 진짜 원본 백업을 덮어쓰지 않기 위해서입니다.
- 한 번 처리한 파일을 다시 넣어도 건너뜁니다. 번역만 한 파일은 대상 언어로 감지되고, 원문을 함께 넣은 파일은 대상 언어 비율이 30%를 넘기 때문입니다.

## 중단 후 이어하기와 복원

- **파일별 체크포인트:** 번역한 문장을 40문장마다 `~/Library/Application Support/JamakTrans/Checkpoints/`에 저장합니다.
  - 중지하거나 앱을 끝내거나 앱이 비정상 종료되어도, 다시 시작하면 중단된 문장부터 이어서 번역합니다.
  - 체크포인트는 원본 파일의 SHA-256으로 확인합니다. 원본이 바뀌면 처음부터 다시 번역합니다.
  - 파일을 끝까지 번역하면 체크포인트를 지우고, 30일 동안 쓰지 않은 체크포인트도 자동으로 지웁니다.
- **세션 복원:** 작업 목록을 `session.json`에 자동으로 저장하고, 다음 실행 때 복원합니다.
  - 복원 후 바로 번역을 시작하지 않고 "이어서 번역" 배너를 보여줍니다.
  - 앱을 끝낼 때 진행 중인 작업을 멈추고 체크포인트를 저장한 뒤 종료합니다(최대 3초).
- **작업 목록 저장/불러오기:** 파일 메뉴에서 저장(⌘S), 불러오기(⇧⌘O)로 목록을 JSON 파일로 저장하고 다시 불러옵니다.

## 자막 처리

- 인코딩: UTF-8/16(BOM), CP949, Shift-JIS, GB18030, Big5, Windows-1252를 자동 감지합니다.
- `{\an8}` 위치 태그, 전체 기울임 `<i>…</i>`, 대화 대시(`- `)는 유지합니다. 그 밖의 인라인 태그는 지웁니다.
- 여러 줄로 된 자막은 한 문장으로 합쳐 번역한 뒤, 띄어쓰기가 있는 언어는 다시 두 줄로 나눕니다.
- 글자가 없는 자막(♪ 등)은 그대로 둡니다.

## 자동 업데이트

[sugyeol](https://github.com/ziozzang/sugyeol)과 같은 방식으로 GitHub Releases를 씁니다.

- 앱을 실행하면 하루에 한 번 `api.github.com/repos/ziozzang/jamak-trans/releases/latest`를 확인합니다. 앱 메뉴의 **업데이트 확인…**으로 직접 확인할 수도 있고, **자동으로 업데이트 확인**으로 끌 수도 있습니다. 환경 변수 `JAMAK_TRANS_NO_UPDATE_CHECK`를 설정해도 꺼집니다.
- 새 버전이 있으면 릴리스 노트와 함께 묻습니다(업데이트 후 다시 시작 / 나중에 / 이 버전 건너뛰기). 묻지 않고 설치하지는 않습니다.
- 설치 순서:
  1. `JamakTrans_<버전>_macos_universal.zip`을 내려받으면서 SHA-256을 계산하고, 릴리스의 `SHA256SUMS`와 비교합니다.
  2. 압축을 풀고 번들 ID와 버전이 맞는지 확인합니다.
  3. 앱을 정상 종료합니다. 이때 작업 목록과 체크포인트가 저장됩니다.
  4. 앱 번들을 교체하고 다시 실행합니다. 번역 중이던 작업은 복원 배너에서 이어서 진행할 수 있습니다.
- 앱이 있는 폴더에 쓸 권한이 있어야 합니다.

## 릴리스 절차

GitHub Actions 없이 직접 빌드하고 배포합니다.

```sh
echo 1.0.1 > VERSION            # 버전은 VERSION 파일 한 곳에서만 관리
scripts/release.sh              # dist/JamakTrans_1.0.1_macos_universal.zip + dist/SHA256SUMS 생성·검증
scripts/release.sh --publish    # 태그 v1.0.1을 푸시하고 GitHub 릴리스 생성 (gh 또는 $GITHUB_TOKEN 필요, 노트는 RELEASE_NOTES.md)
```

## 라이선스

MIT
