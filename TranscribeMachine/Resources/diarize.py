#!/usr/bin/env python3
"""
TranscribeMachine — diarization script (no API token required)
Uses WhisperX for transcription + simple-diarizer (speechbrain) for speaker ID.

Usage:
    python3 diarize.py \
        --audio /path/to/audio.wav \
        --source local \
        --model base.en \
        --out /path/to/result.json

Output JSON:
[
  {"speaker": "SPEAKER_00", "source": "local", "start": 0.0, "end": 2.3, "text": "Hello everyone"},
  ...
]
"""

import sys, json, argparse, os, tempfile

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio",  required=True)
    parser.add_argument("--source", required=True, choices=["local", "remote"])
    parser.add_argument("--model",  default="base.en")
    parser.add_argument("--out",    required=True)
    args = parser.parse_args()

    try:
        import whisperx
        import torch
    except ImportError:
        return err(args.out, "whisperx not installed. Run the setup from TranscribeMachine.")

    device = "mps" if torch.backends.mps.is_available() else "cpu"

    # ── 1. Transcribe ─────────────────────────────────────────────────────────
    try:
        model = whisperx.load_model(args.model, device, compute_type="float32")
        audio = whisperx.load_audio(args.audio)
        result = model.transcribe(audio, batch_size=8)
    except Exception as e:
        return err(args.out, f"Transcription failed: {e}")

    # ── 2. Word-level alignment ───────────────────────────────────────────────
    try:
        lang = result.get("language", "en")
        align_model, metadata = whisperx.load_align_model(language_code=lang, device=device)
        result = whisperx.align(result["segments"], align_model, metadata, audio, device)
    except Exception:
        pass  # alignment optional

    # ── 3. Speaker diarization via simple-diarizer (no token) ────────────────
    diarized = False
    try:
        from simple_diarizer.diarizer import Diarizer

        # Write audio to temp wav if needed
        tmp_wav = args.audio
        diar = Diarizer(
            embed_model="xvec",        # or "ecapa" — both free
            cluster_method="sc"        # spectral clustering
        )

        segments_diar = diar.diarize(tmp_wav, num_speakers=None)  # auto-detect count
        # segments_diar: list of {start, end, label}

        # Map diarizer segments onto whisperx segments by overlap
        for wx_seg in result.get("segments", []):
            best_speaker = "SPEAKER_00"
            best_overlap = 0.0
            ws = wx_seg.get("start", 0)
            we = wx_seg.get("end", 0)

            for ds in segments_diar:
                ds_start = ds["start"] / 1000.0 if ds["start"] > 100 else ds["start"]
                ds_end   = ds["end"]   / 1000.0 if ds["end"]   > 100 else ds["end"]
                overlap = max(0, min(we, ds_end) - max(ws, ds_start))
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_speaker = f"SPEAKER_{int(ds['label'].replace('SPEAKER_', '').replace('spk', '')):02d}" \
                                   if ds["label"] else "SPEAKER_00"

            wx_seg["speaker"] = best_speaker

        diarized = True

    except ImportError:
        pass  # simple-diarizer not installed — fall through to fallback
    except Exception as e:
        print(f"[diarize.py] Diarization warning: {e}", file=sys.stderr)

    # ── 4. Fallback: basic VAD-based speaker splitting ────────────────────────
    if not diarized:
        try:
            _vad_assign(result.get("segments", []))
        except Exception:
            for seg in result.get("segments", []):
                seg.setdefault("speaker", "SPEAKER_00")

    # ── 5. Write output ───────────────────────────────────────────────────────
    out = []
    for seg in result.get("segments", []):
        out.append({
            "speaker": seg.get("speaker", "SPEAKER_00"),
            "source":  args.source,
            "start":   round(seg.get("start", 0), 3),
            "end":     round(seg.get("end",   0), 3),
            "text":    seg.get("text", "").strip()
        })

    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)

    n_speakers = len({s["speaker"] for s in out})
    print(f"[diarize.py] Done — {len(out)} segments, {n_speakers} speaker(s) detected → {args.out}")


def _vad_assign(segments):
    """
    Rough heuristic: cluster by silence gaps > 1.5s.
    Not great but works as a last resort.
    """
    if not segments:
        return
    speaker_id = 0
    prev_end = 0.0
    for seg in segments:
        if seg.get("start", 0) - prev_end > 1.5:
            speaker_id = (speaker_id + 1) % 4  # cycle through up to 4 labels
        seg["speaker"] = f"SPEAKER_{speaker_id:02d}"
        prev_end = seg.get("end", prev_end)


def err(out_path, msg):
    print(f"[diarize.py] ERROR: {msg}", file=sys.stderr)
    with open(out_path, "w") as f:
        json.dump({"error": msg}, f)


if __name__ == "__main__":
    main()
