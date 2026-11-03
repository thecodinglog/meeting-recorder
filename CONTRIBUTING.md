# 기여 안내

버그 수정, 설치 안내 개선, 장치 호환성 보고를 환영합니다. 큰 기능 변경은 먼저 이슈에서 사용 사례와 범위를 설명해 주세요. 한국어와 영어 모두 가능합니다.

## 개발 환경과 확인

macOS 15 이상과 Xcode 16 이상의 Swift 6 도구를 사용합니다. 녹음·편집 테스트에는 전사 모델이나 Python 패키지가 필요하지 않습니다.

```sh
swift test
CODE_SIGN_IDENTITY=- ./build.sh
bash -n build.sh make_icon.sh
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("diarize/diarize.py").read_text())'
git diff --check
```

`swift test`는 합성 오디오를 만들며 실제 마이크나 통화 소리를 녹음하지 않습니다. `--selftest`와 `--lifecycle-check`는 실제 장치를 사용하는 앱 실행 옵션이므로 CI에 넣지 않습니다. 녹음 경로를 변경했다면 동의를 받은 환경에서 시스템 소리·마이크·저장·재생을 별도로 확인해 주세요.

## 코드 구성

- `Sources/AudioCapture.swift`, `AudioSink.swift`, `Mixer.swift`: 오디오 수집·저장·믹싱
- `Sources/MeetingWatcher.swift`: 회의·전화 감지와 제안
- `Sources/Recording*.swift`: 보관 위치·목록·재생·편집·백업
- `Sources/Transcriber.swift`, `TranscriptionPaths.swift`: 전사 실행과 구성 경로
- `diarize/`: 선택적 Python 화자 구분
- `Tests/`: Swift Testing 기반 회귀 검사

기존의 한국어 UI·주석 스타일을 따르고 변경 범위를 작게 유지합니다. 오디오 손실, 편집, 백업 삭제, 자동 녹음 동작을 바꿀 때는 해당 동작을 검증하는 테스트를 함께 추가합니다. 예제 음성은 합성하거나 재배포할 수 있는 자료를 사용합니다.

## 이슈·PR

재현 단계, 기대 결과, 실제 결과와 macOS·Xcode 버전, CPU 종류, 오디오 장치를 적어 주세요. 로그는 문제와 관련된 부분만 첨부하고 이름·경로·회의 내용·토큰을 지웁니다. PR에는 변경 이유와 실행한 검증을 적습니다. 실제 녹음, 모델, 가상환경, 인증서, 빌드 결과물은 커밋하지 않습니다.

보안 문제는 [SECURITY.md](SECURITY.md)의 비공개 제보 절차를 따릅니다. 기여한 코드는 이 저장소의 [MIT License](LICENSE)로 제공하며, 직접 작성했거나 이 조건으로 제공할 권한이 있는 변경만 제출해 주세요.
