#!/bin/bash

# Define required commands
# REQUIRED_COMMANDS=(stable-ts demucs ffprobe ffmpeg)
# REQUIRED_COMMANDS=(whisperx ffprobe ffmpeg demucs)
REQUIRED_COMMANDS=(whisper-cli ffprobe ffmpeg demucs)

# Check if all required commands are available
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Transcribing commands are not available."
        exit 1
    fi
done

#################################
# for whisper-cli
#################################
if ! command -v aria2c >/dev/null && ! command -v curl >/dev/null; then
    echo "Neither aria2c nor curl is available."
    exit 1
fi

MODEL_DIR="$HOME/.cache/whisper.cpp"
MODEL="$MODEL_DIR/ggml-large-v3-turbo.bin"

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
mkdir -p "$MODEL_DIR"
if [[ ! -f "$MODEL" ]]; then
    if command -v aria2c >/dev/null; then
        aria2c -R -x16 -s32 -d "$MODEL_DIR" -o "$(basename "$MODEL")" "$MODEL_URL" || curl -L "$MODEL_URL" -o "$MODEL"
    else
        curl -L "$MODEL_URL" -o "$MODEL"
    fi
fi

WHISPER_GPU=(-dev 0)
WHISPER_ARGS=(
    -m "$MODEL"
    -osrt
    --max-context 0
    --no-speech-thold 0.6
    --entropy-thold 2.4
    --logprob-thold -1.0
    "${WHISPER_GPU[@]}"
)

#################################
# for demucs
#################################
detect_torch_device() {
    if ! command -v python3.12 >/dev/null; then
        printf '%s\n' default
        return
    fi

    python3.12 - <<'PYTORCH_DETECT' 2>/dev/null
import sys
try:
    import torch
except Exception:
    sys.exit(1)

if torch.cuda.is_available():
    print("cuda")
elif hasattr(torch, "xpu") and torch.xpu.is_available():
    print("xpu")
elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
    print("mps")
else:
    print("cpu")
PYTORCH_DETECT

    [[ $? -eq 0 ]] || printf '%s\n' default
}

DEMUCS_DEVICE_RESOLVED="$(detect_torch_device)"

if [[ "$DEMUCS_DEVICE_RESOLVED" == "default" ]]; then
    echo "Using Demucs device: demucs default"
else
    echo "Using Demucs device: $DEMUCS_DEVICE_RESOLVED"
fi

build_demucs_args() {
    local device="$1"
    DEMUCS_ARGS=(
        -n htdemucs
        -o separated
        --two-stems vocals
        --other-method none
        --shifts 1
        --overlap 0.25
        -j 0
    )

    if [[ "$device" != "default" ]]; then
        DEMUCS_ARGS+=(-d "$device")
    fi
}

run_demucs_with_fallback() {
    local input_file="$1"

    build_demucs_args "$DEMUCS_DEVICE_RESOLVED"
    if demucs "${DEMUCS_ARGS[@]}" "$input_file"; then
        return 0
    fi

    if [[ "$DEMUCS_DEVICE_RESOLVED" != "cpu" ]]; then
        echo "Demucs failed on $DEMUCS_DEVICE_RESOLVED; retrying on CPU."
        build_demucs_args cpu
        demucs "${DEMUCS_ARGS[@]}" "$input_file" && return 0
    fi

    return 1
}

#################################
# for whisperx
#################################
# WX_GPU=(--device cpu --compute_type float32)
# if python3.12 -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
#     WX_GPU=(--device cuda --compute_type float16)
# fi

# Process files in the current directory
for file in *; do
    # Check if file is a video file
    if [[ "$file" =~ \.(mp4|mkv)$ && ! "$file" =~ ^old_ ]]; then
        # Check if file has English subtitles
        if ! ffprobe -loglevel error -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 "$file" | grep -q "eng"; then
            # Extract filename and extension
            filename=$(basename "$file" | sed "s/\.[^.]*$//")
            extension="${file##*.}"

            # Rename original file
            mv -fv "$file" "old_$file"

            # Transcribe audio to subtitle file
            # stable-ts --faster_whisper --task translate --vad=True --model turbo "old_$file" -o "${filename}.srt"
            # whisperx --model turbo "${WX_GPU[@]}" --output_dir . --output_format srt --print_progress True "old_$file"

            # After source separation, convert vocals to the format expected by Whisper
            demucs_input="old_${filename}.demucs.wav"
            asr_audio="old_${filename}.asr.wav"
            demucs_track="$(basename "$demucs_input" | sed "s/\.[^.]*$//")"
            vocals_file="./separated/htdemucs/${demucs_track}/vocals.wav"

            ffmpeg -y -i "old_$file" -vn -ac 2 -ar 44100 "$demucs_input" || exit 1

            run_demucs_with_fallback "$demucs_input" || exit 1
            [[ -f "$vocals_file" ]] || { echo "Demucs vocals file not found: $vocals_file"; exit 1; }

            ffmpeg -y -i "$vocals_file" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$asr_audio" || exit 1
            whisper-cli "${WHISPER_ARGS[@]}" -f "$asr_audio" -of "old_${filename}" || exit 1

            srtfile="old_${filename}.srt"

            [[ -f "$srtfile" ]] || exit 1

            # Merge subtitle file with original video file
            if ffmpeg -i "old_$file" -i "$srtfile" -map 0:v -map 0:a? -map 1:0 -c:v copy -c:a copy -c:s srt -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" -disposition:s:0 default "${filename}.mkv"; then
                # Remove temporary subtitle file
                rm -rfv "$srtfile" "$demucs_input" "$asr_audio"
            fi
        fi
    fi
done