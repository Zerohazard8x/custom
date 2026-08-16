#!/bin/bash

# Core commands required regardless of which transcription backend is selected.
# `ffprobe` checks subtitle streams and `ffmpeg` extracts/converts audio.
REQUIRED_COMMANDS=(ffprobe ffmpeg)

# Stop early if a core dependency is missing.
# `command -v` is used instead of `which` because it is a shell builtin on
# common shells and reliably checks commands available through the current PATH.
# Redirecting stdout to /dev/null keeps this check quiet when a command exists.
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Transcribing commands are not available."
        exit 1
    fi
done

# Build the model/backend menu dynamically.
# Only backends that can actually be used in the current shell environment
# are shown, which prevents the splash screen from offering broken choices.
BACKENDS=()

# Qwen is considered available only when Python 3.12 exists AND both required
# Python modules can be imported from that exact Python environment.
# `&&` is used so the import check is never attempted if python3.12 is absent.
# The short one-line `if ...; then ...; fi` keeps this detection compact.
if command -v python3.12 >/dev/null && python3.12 -c 'import qwen_asr,transformers' 2>/dev/null; then
    BACKENDS+=(qwen)
fi

# WhisperX and stable-ts expose their own CLI commands, so command discovery
# alone is sufficient for displaying them in the selection menu.
if command -v whisperx >/dev/null; then
    BACKENDS+=(whisperx)
fi

if command -v stable-ts >/dev/null; then
    BACKENDS+=(stable-ts)
fi

# `${#BACKENDS[@]}` gives the number of Bash array elements.
# The arithmetic form `(( ... ))` treats zero as false, so this compactly
# aborts when no usable transcription backend was detected.
((${#BACKENDS[@]})) || {
    echo "No transcription model is available."
    exit 1
}

# Clear the terminal and move the cursor to the upper-left corner so the model
# chooser behaves like a small splash screen instead of appearing below old logs.
printf '\033[2J\033[H'

echo "Transcription model"

# Bash array indices start at zero.
# We display `i + 1` because a menu beginning at 1 is more natural for users.
for i in "${!BACKENDS[@]}"; do
    case "${BACKENDS[i]}" in
        qwen)
            name="Qwen3-ASR-1.7B"
            ;;
        whisperx)
            name="WhisperX turbo"
            ;;
        stable-ts)
            name="stable-ts turbo"
            ;;
    esac

    printf '%d) %s\n' "$((i+1))" "$name"
done

# No explicit "default backend" variable is needed.
# BACKENDS was populated in priority order:
# Qwen -> WhisperX -> stable-ts.
# Therefore BACKENDS[0] automatically represents the best available fallback.
printf 'Choose [1-%d] (auto in 5s): ' "${#BACKENDS[@]}"

choice=""

# Read a single character from the actual terminal and wait at most five seconds.
#
# Why this exact syntax:
#   - `-r` prevents backslash processing.
#   - `-t 5` implements the five-second automatic selection timeout.
#   - `-n 1` means the user can simply press "1", "2", etc. without Enter.
#   - `</dev/tty` deliberately reads from the interactive terminal rather than
#     standard input, because the script might itself be launched through a
#     pipe or another redirected environment.
#   - `|| true` prevents a normal timeout from being treated as a fatal error.
[[ -r /dev/tty ]] && read -r -t 5 -n 1 choice </dev/tty || true

# Move output to a fresh line after the single-character prompt.
echo

# Accept the user's choice only when it is a valid positive menu number.
# Bash array indexing is zero-based, hence `choice - 1`.
if [[ "$choice" =~ ^[1-9]$ ]] && ((choice <= ${#BACKENDS[@]})); then
    ASR_BACKEND="${BACKENDS[choice-1]}"
else
    # Timeout, blank input, or invalid input selects the first available backend.
    ASR_BACKEND="${BACKENDS[0]}"
fi

echo "Using: $ASR_BACKEND"


#################################
# Process video files
#################################

# Iterate over ordinary entries in the current directory.
for file in *; do

    # Process MP4/MKV files only.
    # Files beginning with old_ are skipped because those are originals that
    # this script has already renamed and preserved.
    if [[ "$file" =~ \.(mp4|mkv)$ && ! "$file" =~ ^old_ ]]; then

        # Skip videos already containing an English subtitle stream.
        #
        # ffprobe prints subtitle stream indices/language tags as CSV.
        # grep only has to find "eng" to indicate an existing English stream.
        if ! ffprobe \
            -loglevel error \
            -select_streams s \
            -show_entries stream=index:stream_tags=language \
            -of csv=p=0 \
            "$file" | grep -q "eng"
        then
            # Remove only the final file extension.
            # This preserves dots elsewhere in filenames.
            filename=$(basename "$file" | sed "s/\.[^.]*$//")

            # Keep the original extension available even though the current
            # processing path does not otherwise need to branch on it.
            extension="${file##*.}"

            # Preserve the original input before creating the new MKV.
            mv -fv "$file" "old_$file"

            asr_audio="old_${filename}.asr.wav"

            # All backends ultimately produce this same SRT path, allowing the
            # muxing code below to be completely backend-independent.
            srtfile="old_${filename}.srt"


            #################################
            # Prepare speech audio
            #################################

            # Mono/16 kHz reduces unnecessary data while matching the format
            # commonly expected by speech recognition pipelines.
            ffmpeg \
                -y \
                -i "old_$file" \
                -vn \
                -ac 1 \
                -ar 16000 \
                -c:a pcm_s16le \
                "$asr_audio" || exit 1


            #################################
            # Transcription backend
            #################################

            case "$ASR_BACKEND" in

                qwen)
                    # Qwen3-ASR itself performs transcription.
                    # Qwen3-ForcedAligner supplies timestamps.
                    # Qwen3-0.6B then translates each finished subtitle cue
                    # into English because Qwen3-ASR does not expose Whisper's
                    # native speech-to-English `translate` task.

                    # The audio and SRT paths are passed as argv[1] and argv[2].
                    # This avoids embedding shell filenames directly into Python
                    # source, which is safer for spaces and unusual characters.
                    #
                    # The quoted heredoc delimiter prevents Bash from expanding
                    # anything in the Python source before execution.
                    python3.12 - "$asr_audio" "$srtfile" <<'PYQWEN' || exit 1
import sys
import time

from qwen_asr import Qwen3ASRModel
from transformers import AutoTokenizer, AutoModelForCausalLM


# Load the speech recognizer and its matching forced aligner.
#
# `device_map="auto"` lets Transformers/Accelerate choose suitable available
# devices rather than hard-coding CUDA or CPU here.
# `dtype="auto"` similarly allows the model library to choose an appropriate
# numerical type for the available hardware.
m = Qwen3ASRModel.from_pretrained(
    "Qwen/Qwen3-ASR-1.7B",
    dtype="auto",
    device_map="auto",
    max_new_tokens=4096,
    forced_aligner="Qwen/Qwen3-ForcedAligner-0.6B",
    forced_aligner_kwargs={
        "dtype": "auto",
        "device_map": "auto",
    },
)

# Request timestamps because SRT requires explicit start/end times.
# `language=None` leaves source-language detection to the ASR model.
a = list(
    m.transcribe(
        audio=sys.argv[1],
        language=None,
        return_time_stamps=True,
    )[0].time_stamps
)


# Load the small text model used only for translation to English.
tok = AutoTokenizer.from_pretrained("Qwen/Qwen3-0.6B")

lm = AutoModelForCausalLM.from_pretrained(
    "Qwen/Qwen3-0.6B",
    torch_dtype="auto",
    device_map="auto",
)


def tr(s):
    """Translate one completed subtitle cue into English."""

    # Use Qwen's chat template so the tokenizer adds the exact conversation
    # structure expected by the model.
    #
    # `enable_thinking=False` is intentional: subtitle translation needs a
    # concise answer only, and reasoning would waste tokens and could place
    # unwanted prose into the SRT.
    x = tok.apply_chat_template(
        [
            {
                "role": "user",
                "content":
                    "Translate this subtitle to natural English. "
                    "Output only the translation:\n" + s,
            }
        ],
        tokenize=False,
        add_generation_prompt=True,
        enable_thinking=False,
    )

    # Convert the formatted prompt to tensors and move them to the same device
    # chosen for the translation model.
    x = tok([x], return_tensors="pt").to(lm.device)

    # Deterministic generation is used because subtitle translation should be
    # repeatable rather than vary between runs.
    y = lm.generate(
        **x,
        max_new_tokens=256,
        do_sample=False,
    )

    # The generated tensor contains the original prompt followed by new tokens.
    # Slice away exactly the prompt length so only the translation is decoded.
    return tok.decode(
        y[0][x["input_ids"].shape[-1]:],
        skip_special_tokens=True,
    ).strip()


def ts(x):
    """Convert floating-point seconds to SRT's HH:MM:SS,mmm format."""

    # `gmtime` is useful here because it formats a duration from zero without
    # introducing local timezone offsets.
    #
    # The fractional part is multiplied by 1000 to obtain milliseconds.
    return (
        time.strftime("%H:%M:%S", time.gmtime(x))
        + f",{int(x % 1 * 1000):03}"
    )


# Write the final SRT directly to the path supplied by the shell script.
with open(sys.argv[2], "w") as f:

    # Combine ten aligned timestamp items into one subtitle cue.
    # This prevents every individual word/token from becoming its own SRT entry.
    for n, i in enumerate(range(0, len(a), 10), 1):
        p = a[i:i + 10]

        # Translate after grouping so the language model receives enough context
        # to produce a natural English subtitle sentence.
        text = tr(" ".join(x.text for x in p))

        # SRT entries contain:
        #   cue number
        #   start --> end
        #   subtitle text
        #   blank separator line
        f.write(
            f"{n}\n"
            f"{ts(p[0].start_time)} --> {ts(p[-1].end_time)}\n"
            f"{text}\n\n"
        )
PYQWEN
                    ;;


                whisperx)
                    # WhisperX can use CPU everywhere, so start with a safe CPU
                    # configuration and replace it only when CUDA is confirmed.
                    WX_GPU=(--device cpu --compute_type float32)

                    # Use the same Python/PyTorch CUDA check as the rest of the
                    # environment rather than assuming that an NVIDIA driver
                    # automatically means WhisperX has a CUDA-capable PyTorch.
                    if command -v python3.12 >/dev/null &&
                        python3.12 -c \
                            'import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)' \
                            2>/dev/null
                    then
                        WX_GPU=(--device cuda --compute_type float16)
                    fi

                    # `--task translate` requests English output.
                    # The array expansion preserves the CPU/GPU arguments as
                    # individual CLI parameters.
                    whisperx \
                        --task translate \
                        --model turbo \
                        "${WX_GPU[@]}" \
                        --output_dir . \
                        --output_format srt \
                        --print_progress True \
                        "$asr_audio" || exit 1

                    # WhisperX names its output after the WAV input.
                    # Rename it to the common filename expected below.
                    mv -f "${asr_audio%.*}.srt" "$srtfile" || exit 1
                    ;;


                stable-ts)
                    # stable-ts uses faster-whisper here and asks Whisper to
                    # translate recognized speech into English.
                    stable-ts \
                        --faster_whisper \
                        --task translate \
                        --vad=True \
                        --denoiser demucs \
                        --model turbo \
                        "old_$file" \
                        -o "$srtfile" || exit 1
                    ;;
            esac


            #################################
            # Mux subtitles into final MKV
            #################################

            # Refuse to mux anything if the selected backend did not actually
            # create the expected subtitle file.
            [[ -f "$srtfile" ]] || exit 1

            # Create a new MKV from the preserved original.
            #
            # Mapping:
            #   `-map 0:v`  = video from original input
            #   `-map 0:a?` = audio from original input; `?` makes audio optional
            #   `-map 1:0`  = the SRT subtitle stream from the second input
            #
            # Video and audio are copied rather than re-encoded, avoiding
            # generation loss and greatly reducing processing time.
            #
            # The subtitle stream is explicitly tagged as English because every
            # backend path above requests or performs English translation.
            if ffmpeg \
                -i "old_$file" \
                -i "$srtfile" \
                -map 0:v \
                -map 0:a? \
                -map 1:0 \
                -c:v copy \
                -c:a copy \
                -c:s srt \
                -metadata:s:s:0 language=eng \
                -metadata:s:s:0 title="English" \
                -disposition:s:0 default \
                "${filename}.mkv"
            then
                # Remove only temporary transcription/audio files after the
                # final MKV has been created successfully.
                #
                # The preserved `old_...` original is intentionally retained.
                rm -rfv "$srtfile" "$asr_audio"
            fi
        fi
    fi
done