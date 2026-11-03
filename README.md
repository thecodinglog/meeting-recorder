# 회의 녹음기 · Meeting Recorder

macOS 메뉴바에서 시스템 오디오와 마이크를 녹음하고, 로컬 모델로 한국어 회의록을 만드는 앱입니다. SwiftUI와 Core Audio로 구현했습니다.

<img src="Resources/AppIcon.png" width="128" alt="회의 녹음기 아이콘" />

## 할 수 있는 일

- 시스템 오디오와 마이크를 별도 트랙으로 저장하고 하나의 M4A로 합치기
- Teams·NAVER WORKS·Zoom 등의 마이크 사용을 감지해 녹음 시작·정지 제안
- 전화 앱의 통화 감지 시 자동 녹음하는 설정(기본 켜짐)
- 녹음 중 자동 화면 꺼짐·잠자기 방지 설정(기본 켜짐, 설정 유지)
- 녹음 목록, 재생, 파형 탐색, 이름 변경, 구간 자르기와 원본 ZIP 백업
- whisper.cpp로 한국어 전사, 선택적으로 ECAPA 모델로 화자 구분
- 녹음 저장 위치 변경, 기존 위치의 녹음 열기, 로그인 시 실행 설정

녹음 전에 참석자에게 알리고 동의를 받으세요. 회의 봇이나 참석자 알림은 제공하지 않습니다. 시스템 오디오에는 회의 외의 알림음·음악도 포함될 수 있습니다.

## 요구 사항

| 기능 | 필요한 것 |
| --- | --- |
| 빌드·녹음·편집 | macOS 15 이상, Xcode 16 이상(Swift 6 포함) |
| 한국어 회의록 | `whisper-cli`, Whisper 모델 |
| 상대방 여러 명의 화자 구분 | Python 3.12, `diarize/requirements.txt`의 패키지, ECAPA 모델 |

Swift 패키지에는 외부 의존성이 없습니다. 전사·화자 구분은 선택 사항이며, 설치하지 않아도 녹음과 편집은 가능합니다. 개발 검증 환경은 Apple Silicon입니다. Intel Mac과 모든 회의 앱·오디오 장치 조합에서의 동작을 보장하지 않습니다.

## 소스에서 실행

Xcode를 설치하고 처음 실행해 필요한 구성 요소 설치를 마칩니다. 활성 개발 도구는 `xcode-select -p`, Swift 버전은 `swift --version`으로 확인합니다.

```sh
git clone https://github.com/thecodinglog/meeting-recorder.git
cd meeting-recorder
swift test
./build.sh
open build/MeetingRecorder.app
```

`build/MeetingRecorder.app`을 `/Applications`로 옮겨 사용할 수 있습니다. 빌드는 현재 Mac의 아키텍처용입니다. `swift run` 대신 앱 번들을 실행해야 권한 설명과 포함된 화자 구분 스크립트를 사용할 수 있습니다.

`build.sh`는 로컬 Apple Development 인증서가 있으면 사용하고, 없으면 임시 서명(ad-hoc)을 합니다. 서명을 직접 지정하려면 `CODE_SIGN_IDENTITY="인증서 이름 또는 SHA-1" ./build.sh`, 임시 서명을 강제하려면 `CODE_SIGN_IDENTITY=- ./build.sh`를 사용합니다. 임시 서명으로 다시 빌드하면 녹음 권한을 다시 허용해야 할 수 있습니다. 이 빌드는 Developer ID 공증을 거친 배포본이 아닙니다.

처음 녹음할 때 **마이크**, **시스템 오디오 녹음**, 저장 위치 접근 권한을 허용합니다. 화면 영상은 녹화하지 않습니다. 시스템 오디오 권한을 허용한 뒤 앱을 다시 실행해야 할 수 있습니다. 로그인 시 자동 실행은 첫 일반 실행에서 등록을 시도하며, 앱 설정에서 끌 수 있습니다.

## 기본 사용

1. 메뉴바 아이콘을 열고 필요하면 **설정 → 녹음**에서 녹음 옵션을 바꿉니다. 마이크 함께 녹음과 잠자기 방지는 기본 켜짐, 회의록 자동 작성은 기본 꺼짐이며 선택은 다음 실행에도 유지됩니다.
2. **녹음 시작**을 누르고, 끝나면 **녹음 정지**를 누릅니다.
3. **녹음 목록 · 재생과 편집**에서 재생하거나 필요한 구간을 자릅니다.
4. 전사 구성 요소를 설치했다면 **최근 녹음으로 회의록 만들기** 또는 **파일·폴더 골라서 회의록 만들기**를 사용합니다.

회의 감지는 기본적으로 제안 창을 띄우며, 응답하지 않으면 녹음을 시작하지 않습니다. **설정 → 전화 자동 녹음**의 **전화 통화 감지 시 바로 녹음**은 기본 켜짐이며, 확인 창 없이 시작·정지합니다. 설정에서 끌 수 있고 선택은 다음 실행에도 유지됩니다. 통화 소리가 Mac에서 재생되어야 하며, Phone과 FaceTime이 함께 실행되면 자동 감지가 제한될 수 있습니다. 전화 앱의 제공 여부는 macOS 버전에 따라 다릅니다.

**설정 → 녹음**에서 **녹음 중 화면 꺼짐·잠자기 방지**(기본 켜짐)를 바꿀 수 있습니다. 녹음 중 변경은 즉시 반영되고 선택은 다음 실행에도 유지됩니다. 녹음이 끝나면 방지가 해제됩니다. 덮개를 닫거나 직접 잠자기를 선택하는 동작은 막지 않습니다.

## 회의록 설치(선택)

[Homebrew](https://brew.sh/)가 설치되어 있는 환경에서 실행합니다. 모델 다운로드에는 인터넷 연결과 저장 공간이 필요합니다. 앱은 모델을 자동 다운로드하지 않습니다.

```sh
brew install whisper.cpp
mkdir -p "$HOME/models"
curl -fL --retry 3 \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin \
  -o "$HOME/models/ggml-large-v3-turbo.bin"
curl -fL --retry 3 \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin \
  -o "$HOME/models/ggml-silero-v5.1.2.bin"
```

Whisper 모델은 약 1.6GB입니다. VAD 모델은 선택 사항이며 무음 구간의 잘못된 전사를 줄이는 데 사용합니다. 다운로드 실패 시 명령을 다시 실행해 완전한 파일을 받으세요. 설치 후 앱을 다시 열고 **도움말 → 구성 요소 상태**를 확인합니다. 전사 언어는 현재 한국어(`ko`)로 고정되어 있습니다.

설치 방식은 [Homebrew 패키지 안내](https://formulae.brew.sh/formula/whisper.cpp), 모델은 [whisper.cpp 문서](https://github.com/ggml-org/whisper.cpp)를 참고하세요.

### 화자 구분 설치(선택, Apple Silicon)

```sh
brew install python@3.12
MR_VENV="$HOME/Library/Application Support/MeetingRecorder/venv"
"$(brew --prefix python@3.12)/bin/python3.12" -m venv "$MR_VENV"
"$MR_VENV/bin/python" -m pip install -r diarize/requirements.txt
mkdir -p "$HOME/models/speaker-ecapa-voxceleb"
curl -fL --retry 3 \
  https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb/resolve/main/embedding_model.ckpt \
  -o "$HOME/models/speaker-ecapa-voxceleb/embedding_model.ckpt"
```

위 명령은 소스 저장소 루트에서 실행합니다. 가상환경은 저장소 밖에 만들어지므로 소스 폴더를 옮겨도 유지됩니다. 의존성 목록은 주요 패키지 버전을 지정하지만 전체 하위 의존성을 고정한 잠금 파일은 아닙니다. 모델의 용도와 조건은 [SpeechBrain 모델 카드](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)를 확인하세요.

화자 번호는 먼저 말한 순서대로 붙이며 실제 신원을 식별하지 않습니다. 겹치는 말, 짧은 발화, 비슷한 목소리에서는 잘못 나눌 수 있습니다. 구성 요소가 없거나 화자 구분이 실패하면 번호 없는 기본 화자로 전사를 계속합니다.

### 경로를 직접 지정하려면

기본 탐색 위치는 Apple Silicon의 `/opt/homebrew/bin/whisper-cli`, Intel의 `/usr/local/bin/whisper-cli`, `~/models`, 위의 앱 전용 가상환경입니다. 기존 `~/projects/meeting-recorder/.venv`도 마지막 대체 경로로 지원합니다.

다른 위치를 사용하려면 앱을 종료한 뒤 필요한 항목만 지정합니다. 값에는 실제 절대 경로를 넣습니다.

```sh
defaults write local.cothe.MeetingRecorder transcription.whisperPath -string "/absolute/path/to/whisper-cli"
defaults write local.cothe.MeetingRecorder transcription.modelsFolder -string "/absolute/path/to/models"
defaults write local.cothe.MeetingRecorder transcription.pythonPath -string "/absolute/path/to/venv/bin/python"
```

모델 폴더 안의 파일명·하위 폴더 구조는 위 예시와 같아야 합니다. 지정값을 해제하려면 해당 키에 `defaults delete local.cothe.MeetingRecorder transcription.pythonPath`와 같은 명령을 사용하고 앱을 다시 실행합니다.

## 저장 파일과 개인정보

기본 저장 위치는 `~/Documents/회의녹음`이며 설정에서 바꿀 수 있습니다. 기존 녹음은 자동 이동하지 않습니다.

| 파일 | 내용 |
| --- | --- |
| `전체.m4a` | 시스템·마이크를 합친 오디오. 이름 변경 가능 |
| `시스템.m4a`, `마이크.m4a` | 분리된 원본 트랙. 마이크를 끄면 마이크 파일 없음 |
| `회의록.txt` | 생성한 회의록 |
| `.tracks.json`, `.recording.json` | 트랙 시간차와 편집·표시 정보 |
| `백업/` | 편집 전 원본 ZIP과 백업 정보 |

편집 전 원본을 ZIP으로 보관하며, 앱이 만든 백업은 **30일 후 자동 삭제**합니다. 별도 장기 보관이 필요하면 다른 위치에 복사하세요. 녹음 파일과 회의록은 앱이 외부 서버로 업로드하지 않습니다. 다만 저장 위치를 iCloud·Dropbox 등 동기화 폴더로 선택하면 해당 서비스가 동기화할 수 있습니다. 파일은 앱이 별도로 암호화하지 않습니다.

실제 녹음, 회의록, 개인 이름·경로가 담긴 로그는 이슈나 PR에 첨부하지 마세요. 자세한 제보 방법은 [SECURITY.md](SECURITY.md)에 있습니다.

## 개발·기여

[CONTRIBUTING.md](CONTRIBUTING.md)에 테스트와 기여 방법을 정리했습니다. 자동 검사는 합성 오디오와 임시 폴더를 사용합니다. 실제 장치의 권한·Bluetooth·통화 녹음은 별도 수동 검증이 필요합니다.

## 라이선스

이 저장소의 코드는 [MIT License](LICENSE)로 공개합니다. 선택적으로 설치하는 도구·라이브러리·모델의 조건은 [THIRD_PARTY.md](THIRD_PARTY.md)를 참고하세요.
