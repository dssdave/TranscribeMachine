#!/bin/bash
# TranscribeMachine — one-time enhanced diarization setup
# No API tokens required.

set -e

echo "[setup] Checking Python..."
if ! command -v python3 &>/dev/null; then
    echo "ERROR: Python 3 not found. Install from https://python.org" >&2
    exit 1
fi
echo "[setup] Found $(python3 --version)"

echo "[setup] Upgrading pip..."
pip3 install --quiet --upgrade pip

echo "[setup] Installing PyTorch..."
# Apple Silicon uses MPS acceleration; Intel uses CPU
pip3 install --quiet torch torchvision torchaudio

echo "[setup] Installing WhisperX..."
pip3 install --quiet whisperx

echo "[setup] Installing simple-diarizer (no API token required)..."
pip3 install --quiet simple-diarizer

echo "[setup] Installing speechbrain..."
pip3 install --quiet speechbrain

echo "[setup] Verifying..."
python3 -c "import whisperx; print('[setup] whisperx OK')"
python3 -c "import torch; print(f'[setup] torch OK — MPS available: {torch.backends.mps.is_available()}')"
python3 -c "from simple_diarizer.diarizer import Diarizer; print('[setup] simple-diarizer OK')"

echo "[setup] All done. Enhanced diarization is ready."
