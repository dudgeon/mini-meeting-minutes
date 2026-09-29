# Vendored models

Every model mini-meeting-minutes uses lives in this directory, so a clone is all the app needs:
nothing is downloaded at runtime. All run on device through Core ML.

| Directory | Purpose | Source | License |
|---|---|---|---|
| `parakeet-redux/` | Speech recognition, 25 languages | [FluidInference/parakeet-redux-coreml](https://huggingface.co/FluidInference/parakeet-redux-coreml), a Core ML conversion of [moondream/parakeet-redux](https://huggingface.co/moondream/parakeet-redux), a ternary retraining of [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) |
| `speaker-diarization/` | Speaker segmentation, voice embeddings, PLDA scoring | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), Core ML conversions of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) (pyannote; WeSpeaker embedding model; PLDA parameters from BUT Speech@FIT) | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) |
| `silero-vad/` | Voice activity detection | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml), from [Silero VAD](https://github.com/snakers4/silero-vad) | MIT |
| `localvqe/` | Echo cancellation and noise suppression | [FluidInference/localvqe-coreml](https://huggingface.co/FluidInference/localvqe-coreml), from [LocalVQE](https://github.com/localai-org/LocalVQE) | Apache-2.0 |

Exact revisions and per-file SHA-256 checksums are in [`manifest.json`](manifest.json).

## Attribution

- **Parakeet Redux**: model by moondream (vik), derived from NVIDIA's Parakeet TDT 0.6B v3; Core ML
  conversion by Fluid Inference. Modified from the original: converted to Core ML.
- **Speaker diarization**: pyannote.audio community-1 pipeline by pyannote (Hervé Bredin et al.),
  speaker embedding model from WeSpeaker, PLDA parameters by Brno University of Technology,
  BUT Speech@FIT. Converted to Core ML (fixed input shapes, mixed-precision weights, FBank front end
  split from the embedding model) by Fluid Inference. See the source repository's NOTICE.md.
- **Silero VAD** by Silero Team; Core ML conversion by Fluid Inference.
- **LocalVQE** by LocalAI, derived from DeepVQE (Indenbom et al., Interspeech 2023); Core ML
  conversion by Fluid Inference.

The first-name list used for redaction (`Sources/MinutesCore/Redaction/FirstNames.swift`) is
derived from US Social Security Administration baby-name data (public domain), via the CC0
[babynames](https://github.com/hadley/babynames) R package.

## Why some files are split

GitHub rejects files over 100 MiB and warns above 50 MiB, so `scripts/vendor_models.py` splits
larger files into `.part-NNN` pieces of at most 45 MiB. On first run the app joins them back
together and checks each result against the SHA-256 in `manifest.json`; the joined files are
gitignored. Today only the speech recognizer's encoder (`parakeet-redux/Encoder.mlmodelc/weights/weight.bin`,
183 MB) is split.

## Updating

```sh
python3 scripts/vendor_models.py
```

Edit the revisions in the script first. It downloads only files that changed, re-splits them,
and rewrites `manifest.json` and the reassembled-file entries in `.gitignore`. Every model
update adds its full size to the repository's history, so update deliberately.
