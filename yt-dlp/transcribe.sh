#!/bin/bash

# Print each phase normally and, when stdout is a terminal, also place it in the
# terminal/tab title so the current operation remains visible while output scrolls.
status() {
    [[ -t 1 ]] && printf '\033]0;%s\007' "$1"
    printf '\n== %s ==\n' "$1"
}

status "Checking dependencies"

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
status "Detecting transcription backends"
BACKENDS=()

# Qwen is considered available only when Python 3.12 exists AND both required
# Python modules can be imported from that exact Python environment.
# `&&` is used so the import check is never attempted if python3.12 is absent.
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

# Count candidate videos once so the same total can be shown everywhere.
status "Counting videos"
N=0
for f in *; do
    [[ "$f" =~ \.(mp4|mkv)$ && ! "$f" =~ ^old_ ]] && ((N++))
done

# Clear the terminal and move the cursor to the upper-left corner so the model
# chooser behaves like a small splash screen instead of appearing below old logs.
printf '\033[2J\033[H'

echo "Transcription model"
echo "Videos: $N"

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
file_no=0
for file in *; do

    # Process MP4/MKV files only.
    # Files beginning with old_ are skipped because those are originals that
    # this script has already renamed and preserved.
    if [[ "$file" =~ \.(mp4|mkv)$ && ! "$file" =~ ^old_ ]]; then
        ((file_no++))
        status "Checking: $file ($file_no/$N)"

        # Skip videos already containing an English subtitle stream.
        #
        # `warning` allows useful ffprobe diagnostics through without flooding
        # the screen with normal probe details; stdout remains machine-readable.
        if ! ffprobe \
            -v warning \
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

            status "Preparing audio: $file ($file_no/$N)"

            # `-loglevel info -stats` shows meaningful FFmpeg decisions plus its
            # live progress line, while `-hide_banner` removes repetitive build info.
            ffmpeg \
                -hide_banner \
                -loglevel info \
                -stats \
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
                    status "Transcribing with Qwen3-ASR: $file ($file_no/$N)"

                    # Qwen3-ASR performs transcription and language detection.
                    # Qwen3-ForcedAligner supplies word/character timestamps.
                    #
                    # If Qwen reports exactly "English", its transcript is used
                    # directly. For other or mixed languages, Qwen3-0.6B is loaded
                    # only then and translates each finished source subtitle cue.
                    #
                    # If an English translation becomes longer than the subtitle
                    # limits, it is split again and its source-aligned time interval
                    # is divided proportionally among the resulting English cues.
                    python3.12 - "$asr_audio" "$srtfile" <<'PYQWEN' || exit 1
import re
import sys
import time

from qwen_asr import Qwen3ASRModel
from transformers import AutoTokenizer, AutoModelForCausalLM


print("Qwen: loading ASR + forced aligner...", flush=True)

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

print("Qwen: transcribing + aligning...", flush=True)

# Keep the complete result because `text` retains the ASR punctuation while
# `time_stamps` contains the aligner's punctuation-stripped timed units.
r = m.transcribe(
    audio=sys.argv[1],
    language=None,
    return_time_stamps=True,
)[0]

a = list(r.time_stamps)

print("Qwen: detected language:", r.language, flush=True)


# Subtitle limits.
MAX_DURATION = 7.0
MAX_CHARS = 84
LINE_WIDTH = 42
PAUSE_SPLIT = 0.5
MIN_CHARS_FOR_PAUSE = 24


# Load the translation model only when the complete recording was not detected
# as English. A mixed value such as "Chinese,English" therefore still translates.
if r.language != "English":
    print("Qwen: loading English translation model...", flush=True)

    tok = AutoTokenizer.from_pretrained("Qwen/Qwen3-0.6B")

    lm = AutoModelForCausalLM.from_pretrained(
        "Qwen/Qwen3-0.6B",
        torch_dtype="auto",
        device_map="auto",
    )

    def tr(s):
        """Translate one source cue into concise, natural subtitle English."""
        x = tok.apply_chat_template(
            [
                {
                    "role": "user",
                    "content":
                        "Translate the following dialogue into concise, natural "
                        "English subtitles. Preserve the full meaning, names, "
                        "numbers, tone, and sentence-ending punctuation, but use "
                        "the shortest natural wording that does not lose meaning. "
                        "Do not explain, label, quote, or add anything. "
                        "Output only the English translation:\n" + s,
                }
            ],
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        x = tok([x], return_tensors="pt").to(lm.device)
        y = lm.generate(**x, max_new_tokens=256, do_sample=False)
        return tok.decode(
            y[0][x["input_ids"].shape[-1]:],
            skip_special_tokens=True,
        ).strip()


def ts(x):
    """Convert floating-point seconds to SRT's HH:MM:SS,mmm format."""
    x = max(0.0, x)
    ms = int(round(x * 1000))

    h, ms = divmod(ms, 3600000)
    m_, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)

    return f"{h:02}:{m_:02}:{s:02},{ms:03}"


# Qwen's forced aligner deliberately strips punctuation from its timed units.
# Therefore sentence boundaries are taken from `r.text`, while this helper uses
# Qwen's own aligner tokenizer to find how many timed units belong to a sentence.
def aligned_units(text):
    return m.forced_aligner.aligner_processor.encode_timestamp(
        text,
        r.language,
    )[0]


# Preserve sentence-final punctuation from the ASR transcript. If punctuation
# is absent, the complete text becomes one provisional sentence and the safety
# splitter below divides it using pauses, duration and readable length instead.
def split_sentences(text):
    parts = []
    start = 0

    for match in re.finditer(r'[.!?。！？…]+(?:["”’\)\]]*)', text):
        end = match.end()
        part = text[start:end].strip()
        if part:
            parts.append(part)
        start = end

    tail = text[start:].strip()
    if tail:
        parts.append(tail)

    return parts


# Associate the original punctuated sentences with their corresponding aligned
# timestamps. Reusing Qwen's tokenizer is important because it matches the units
# the forced aligner itself created rather than guessing with `str.split()`.
print("Qwen: finding sentence boundaries...", flush=True)

groups = []
pos = 0

for sentence in split_sentences(r.text):
    count = len(aligned_units(sentence))
    if count == 0:
        continue

    end = min(pos + count, len(a))
    items = a[pos:end]
    pos = end

    if items:
        groups.append((sentence, items))

# Keep any residual aligned items if chunk/tokenization differences leave a few
# timestamps unmatched. Losing the tail of the speech would be worse than a
# punctuation-free final cue.
if pos < len(a):
    groups.append((" ".join(x.text for x in a[pos:]), a[pos:]))


# Split only when a source sentence would otherwise be too long. Natural pauses
# are preferred once a cue contains enough text; hard duration and character
# limits guarantee progress when speech continues without useful pauses.
def split_group(text, items):
    if not items:
        return []

    if (
        len(text) <= MAX_CHARS
        and items[-1].end_time - items[0].start_time <= MAX_DURATION
    ):
        return [(text, items)]

    result = []
    current = []

    for i, item in enumerate(items):
        current.append(item)

        current_text = " ".join(x.text for x in current)
        duration = current[-1].end_time - current[0].start_time
        next_gap = (
            items[i + 1].start_time - item.end_time
            if i + 1 < len(items)
            else 999
        )

        natural_pause = (
            next_gap >= PAUSE_SPLIT
            and len(current_text) >= MIN_CHARS_FOR_PAUSE
        )

        if (
            natural_pause
            or duration >= MAX_DURATION
            or len(current_text) >= MAX_CHARS
            or i == len(items) - 1
        ):
            # The aligner units contain no punctuation. Restore the punctuation
            # belonging to the end of the original sentence on its final chunk.
            if i == len(items) - 1:
                current_text += re.search(
                    r'[^\w\s]*$',
                    text,
                ).group()

            result.append((current_text, current.copy()))
            current = []

    return result


def can_balance(text, width=LINE_WIDTH):
    """Return whether text can fit on one or two lines of at most width."""
    text = " ".join(text.split())

    if len(text) <= width:
        return True

    words = text.split()

    for i in range(1, len(words)):
        left = " ".join(words[:i])
        right = " ".join(words[i:])

        if len(left) <= width and len(right) <= width:
            return True

    return False


def split_for_screen(text):
    """
    Split translated English into chunks that can each fit on at most two
    42-character lines. Prefer punctuation when a suitable earlier break exists.
    """
    text = " ".join(text.split())

    if can_balance(text):
        return [text]

    words = text.split()
    result = []

    while words:
        best = 1
        soft = None

        for n in range(1, len(words) + 1):
            candidate = " ".join(words[:n])

            if not can_balance(candidate):
                break

            best = n

            if re.search(r'[,;:.!?…]["”’\)\]]*$', words[n - 1]):
                soft = n

        # Prefer a reasonably full punctuation boundary instead of breaking at
        # the absolute last word that technically fits.
        if soft is not None:
            soft_text = " ".join(words[:soft])

            if len(soft_text) >= LINE_WIDTH:
                best = soft

        chunk = " ".join(words[:best])
        words = words[best:]

        # An individual token longer than the line width cannot be broken safely
        # without altering its spelling, so preserve it intact.
        result.append(chunk)

    return result


def split_timed_translation(text, start, end):
    """
    Split an overlong English translation and divide its original source timing
    proportionally by visible character count.

    The first and last boundaries remain exactly source-aligned, and adjacent
    translated cues meet without gaps or overlaps.
    """
    parts = split_for_screen(text)

    if len(parts) == 1:
        return [(parts[0], start, end)]

    weights = [
        max(1, len(re.sub(r'\s+', '', part)))
        for part in parts
    ]

    total = sum(weights)
    duration = max(0.001, end - start)

    result = []
    used = 0

    for i, (part, weight) in enumerate(zip(parts, weights)):
        part_start = start + duration * used / total
        used += weight

        if i == len(parts) - 1:
            part_end = end
        else:
            part_end = start + duration * used / total

        result.append((part, part_start, part_end))

    return result


# Make a readable one- or two-line SRT cue without discarding text.
def balance_lines(text, width=LINE_WIDTH):
    text = " ".join(text.split())

    if len(text) <= width:
        return text

    words = text.split()

    if len(words) < 2:
        return text

    candidates = []

    for i in range(1, len(words)):
        left = " ".join(words[:i])
        right = " ".join(words[i:])

        if len(left) <= width and len(right) <= width:
            candidates.append(
                (abs(len(left) - len(right)), left, right)
            )

    if candidates:
        _, left, right = min(candidates, key=lambda x: x[0])
        return left + "\n" + right

    # A single very long token can make the line target impossible.
    # Preserve its exact spelling rather than corrupting or truncating it.
    return text


print("Qwen: building readable source subtitle cues...", flush=True)

source_cues = []

for sentence, items in groups:
    source_cues.extend(split_group(sentence, items))


print("Qwen: translating and finalizing subtitle cues...", flush=True)

cues = []

for text, items in source_cues:
    start = items[0].start_time
    end = items[-1].end_time

    if r.language != "English":
        text = tr(text)

        # Translation can expand substantially relative to the source language.
        # Enforce the English screen limits after translation and derive safe
        # sub-timings from the source-aligned interval when splitting is needed.
        cues.extend(
            split_timed_translation(
                text,
                start,
                end,
            )
        )
    else:
        cues.append((text, start, end))


print(f"Qwen: writing {len(cues)} subtitle cues...", flush=True)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    for n, (text, start, end) in enumerate(cues, 1):
        text = balance_lines(text)

        f.write(
            f"{n}\n"
            f"{ts(start)} --> {ts(end)}\n"
            f"{text}\n\n"
        )

print(f"Qwen: wrote {len(cues)} subtitle cues.", flush=True)
PYQWEN
                    ;;


                whisperx)
                    status "Transcribing with WhisperX: $file ($file_no/$N)"

                    # WhisperX can use CPU everywhere, so start with a safe CPU
                    # configuration and replace it only when CUDA is confirmed.
                    WX_GPU=(--device cpu --compute_type float32)

                    if command -v python3.12 >/dev/null &&
                        python3.12 -c \
                            'import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)' \
                            2>/dev/null
                    then
                        WX_GPU=(--device cuda --compute_type float16)
                    fi

                    # `--verbose True` prints useful transcript details while
                    # `--print_progress True` exposes WhisperX's progress updates.
                    whisperx \
                        --task translate \
                        --model turbo \
                        "${WX_GPU[@]}" \
                        --output_dir . \
                        --output_format srt \
                        --verbose True \
                        --print_progress True \
                        "$asr_audio" || exit 1

                    # WhisperX names its output after the WAV input.
                    # Rename it to the common filename expected below.
                    mv -fv "${asr_audio%.*}.srt" "$srtfile" || exit 1
                    ;;


                stable-ts)
                    status "Transcribing with stable-ts: $file ($file_no/$N)"

                    # stable-ts uses faster-whisper here and asks Whisper to
                    # translate recognized speech into English.
                    #
                    # Demucs is requested through stable-ts itself because its
                    # documented music workflow supports Demucs together with VAD.
                    # `--verbose True` asks stable-ts to display decoded details.
                    stable-ts \
                        --faster_whisper \
                        --task translate \
                        --vad=True \
                        --denoiser demucs \
                        --verbose True \
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

            status "Muxing subtitles: $file ($file_no/$N)"

            # `-loglevel info -stats` keeps FFmpeg's useful stream information
            # and progress visible while suppressing only its repetitive banner.
            if ffmpeg \
                -hide_banner \
                -loglevel info \
                -stats \
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
                # Remove temporary transcription/audio files only after the
                # final MKV has been created successfully.
                # The preserved `old_...` original is intentionally retained.
                rm -rfv "$srtfile" "$asr_audio"
                status "Finished: $file ($file_no/$N)"
            fi
        fi
    fi
done

status "All done ($N videos checked)"