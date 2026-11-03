"""상대방 트랙의 말 조각을 목소리별로 묶는다.

사용: python diarize.py <16kHz 모노 wav> <조각 json> <ECAPA ckpt>
조각 json은 [{"start": 초, "end": 초}, ...] 이고,
표준 출력으로 {"labels": [1, 2, 1, ...], "speakers": 2} 를 낸다.
라벨은 먼저 말한 사람부터 1, 2, ... 순이다.
"""

import json
import sys
import warnings
import wave

warnings.filterwarnings("ignore")

import numpy as np
import torch
from scipy.cluster.hierarchy import fcluster, linkage
from speechbrain.lobes.features import Fbank
from speechbrain.lobes.models.ECAPA_TDNN import ECAPA_TDNN

SAMPLE_RATE = 16_000
MIN_SECONDS = 0.6  # 이보다 짧은 조각은 목소리 특징이 불안정해 앞뒤 조각을 따른다.
MAX_SECONDS = 15.0
# 코사인 거리 기준(유사도 0.4 이상이면 같은 사람). 값이 작을수록 사람을 더 잘게 나눈다.
# 합성 음성 시험에서 같은 사람 0.77~0.92, 다른 사람 0.26 이하였고, 회의 앱 압축 음성을 감안해 여유를 뒀다.
THRESHOLD = 0.6


def load_wav(path):
    with wave.open(path, "rb") as f:
        assert f.getframerate() == SAMPLE_RATE and f.getnchannels() == 1 and f.getsampwidth() == 2
        data = f.readframes(f.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768


def load_model(ckpt):
    # speechbrain/spkrec-ecapa-voxceleb 의 hyperparams.yaml 과 같은 구성
    model = ECAPA_TDNN(
        input_size=80,
        channels=[1024, 1024, 1024, 1024, 3072],
        kernel_sizes=[5, 3, 3, 3, 1],
        dilations=[1, 2, 3, 4, 1],
        attention_channels=128,
        lin_neurons=192,
    )
    model.load_state_dict(torch.load(ckpt, map_location="cpu", weights_only=True))
    return model.eval()


def embed(model, fbank, audio):
    with torch.no_grad():
        feats = fbank(torch.from_numpy(audio).unsqueeze(0))
        feats = feats - feats.mean(dim=1, keepdim=True)  # 문장 단위 평균 정규화
        vector = model(feats).squeeze().numpy()
    return vector / (np.linalg.norm(vector) + 1e-9)


def main():
    wav_path, segments_path, ckpt = sys.argv[1:4]
    torch.set_num_threads(4)
    audio = load_wav(wav_path)
    with open(segments_path, encoding="utf-8") as f:
        segments = json.load(f)

    model = load_model(ckpt)
    fbank = Fbank(n_mels=80)

    usable, vectors = [], []
    for i, seg in enumerate(segments):
        start = int(seg["start"] * SAMPLE_RATE)
        end = int(min(seg["end"], seg["start"] + MAX_SECONDS) * SAMPLE_RATE)
        if (end - start) / SAMPLE_RATE < MIN_SECONDS:
            continue
        usable.append(i)
        vectors.append(embed(model, fbank, audio[start:end]))

    labels = [0] * len(segments)
    if len(vectors) >= 2:
        clusters = fcluster(linkage(np.stack(vectors), method="average", metric="cosine"), THRESHOLD, "distance")
    else:
        clusters = [1] * len(vectors)
    for i, c in zip(usable, clusters):
        labels[i] = int(c)

    # 짧은 조각은 시간상 가장 가까운 조각의 사람을 따른다.
    for i, label in enumerate(labels):
        if label == 0 and usable:
            nearest = min(usable, key=lambda j: abs(segments[j]["start"] - segments[i]["start"]))
            labels[i] = labels[nearest]

    # 먼저 말한 사람부터 1, 2, ... 로 다시 번호를 매긴다.
    order = {}
    for i in sorted(range(len(segments)), key=lambda k: segments[k]["start"]):
        if labels[i] and labels[i] not in order:
            order[labels[i]] = len(order) + 1
    result = [order.get(label, 1) for label in labels]
    print(json.dumps({"labels": result, "speakers": max(len(order), 1)}))


if __name__ == "__main__":
    main()
