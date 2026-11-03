# 외부 도구와 모델

이 저장소의 MIT 라이선스는 외부 도구·라이브러리·모델의 라이선스를 대체하지 않습니다. Swift 앱은 Apple의 시스템 프레임워크를 사용합니다. 아래 구성 요소와 모델 가중치는 저장소나 `build.sh`가 만드는 앱에 포함되지 않으며 사용자가 별도 설치합니다.

| 구성 요소 | 용도 | 원본·라이선스 확인 위치 |
| --- | --- | --- |
| whisper.cpp | 로컬 전사 실행 | [프로젝트 및 LICENSE](https://github.com/ggml-org/whisper.cpp) |
| Whisper large-v3-turbo의 ggml 변환 모델 | 한국어 음성 인식 | [변환 모델](https://huggingface.co/ggerganov/whisper.cpp), [원본 모델 카드](https://huggingface.co/openai/whisper-large-v3-turbo) |
| Silero VAD의 ggml 변환 모델 | 음성 구간 감지 | [변환 모델](https://huggingface.co/ggml-org/whisper-vad), [Silero 프로젝트](https://github.com/snakers4/silero-vad) |
| PyTorch·TorchAudio | 화자 특징 계산 | [PyTorch LICENSE](https://github.com/pytorch/pytorch/blob/main/LICENSE), [TorchAudio LICENSE](https://github.com/pytorch/audio/blob/main/LICENSE) |
| SpeechBrain | ECAPA 네트워크와 음성 특징 | [프로젝트 및 LICENSE](https://github.com/speechbrain/speechbrain) |
| spkrec-ecapa-voxceleb | 화자 특징 모델 | [모델 카드와 라이선스](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb) |
| NumPy·SciPy | 수치 계산과 군집화 | [NumPy LICENSE](https://github.com/numpy/numpy/blob/main/LICENSE.txt), [SciPy LICENSE](https://github.com/scipy/scipy/blob/main/LICENSE.txt) |

재배포할 때는 실제 포함하는 버전의 라이선스와 필요한 고지를 함께 확인하세요. Python 패키지에는 추가 하위 의존성이 있습니다. 위 목록은 설치에 쓰는 주요 구성 요소이며 전체 의존성 명세가 아닙니다.
