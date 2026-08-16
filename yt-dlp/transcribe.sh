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
# Stop early if a core dependency is missing.
for cmd in ffprobe ffmpeg; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Transcribing commands are not available."
        exit 1
    fi
done

# Build the model/backend menu dynamically.
status "Detecting transcription backends"
BACKENDS=()

# Prefer WhisperX first when available.
if command -v python3.12 >/dev/null &&
    python3.12 -c 'import whisperx,torch,tqdm' 2>/dev/null
then
    BACKENDS+=(whisperx)
fi

# Offer Qwen only when both its Python stack and every model needed by this
# workflow are already present in the local Hugging Face cache. This deliberately
# prevents selecting Qwen from triggering a multi-gigabyte model download.
if command -v python3.12 >/dev/null &&
    python3.12 - <<'PYCHECKQWEN' 2>/dev/null
import sys

try:
    import qwen_asr
    import transformers
    import tqdm
    from huggingface_hub import scan_cache_dir

    required = {
        "Qwen/Qwen3-ASR-1.7B",
        "Qwen/Qwen3-ForcedAligner-0.6B",
        "Qwen/Qwen3-0.6B",
    }
    cached = {repo.repo_id for repo in scan_cache_dir().repos}
except Exception:
    sys.exit(1)

sys.exit(0 if required <= cached else 1)
PYCHECKQWEN
then
    BACKENDS+=(qwen)
fi

if command -v stable-ts >/dev/null; then
    BACKENDS+=(stable-ts)
fi

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

# Clear the terminal and move the cursor to the upper-left corner.
printf '\033[2J\033[H'

echo "Transcription model"
echo "Videos: $N"

for i in "${!BACKENDS[@]}"; do
    case "${BACKENDS[i]}" in
        qwen)
            name="Qwen3-ASR-1.7B"
            ;;
        whisperx)
            name="WhisperX large-v3"
            ;;
        stable-ts)
            name="stable-ts large-v3"
            ;;
    esac

    printf '%d) %s\n' "$((i+1))" "$name"
done

# BACKENDS[0] automatically represents the best available fallback.
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
            filename="${file%.*}"

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

                    # Qwen performs ASR and source-language forced alignment in one
                    # blocking transcribe() call. The library does not expose a
                    # public percentage callback for that combined call, so this
                    # script shows an indeterminate moving bar plus elapsed time
                    # there. All loops whose total is known use real tqdm bars.
                    python3.12 - "$asr_audio" "$srtfile" <<'PYQWEN' || exit 1
import re
import sys
import threading
import time

from qwen_asr import Qwen3ASRModel
from tqdm import tqdm
from transformers import AutoTokenizer, AutoModelForCausalLM


# Real progress bars are used where the amount of work is known. For blocking
# library calls with no progress callback, this gives a moving indeterminate bar
# and elapsed time without pretending to know a percentage.
class Activity:
    def __init__(self, label, width=24, interval=0.08):
        self.label = label
        self.width = width
        self.interval = interval
        self.stop = threading.Event()
        self.thread = None
        self.started = None

    def __enter__(self):
        self.started = time.monotonic()

        if not sys.stderr.isatty():
            print(f"{self.label}...", file=sys.stderr, flush=True)
            return self

        def run():
            pos = 0
            direction = 1

            while not self.stop.wait(self.interval):
                bar = [" "] * self.width
                bar[pos] = "█"

                if pos > 0:
                    bar[pos - 1] = "▓"
                if pos > 1:
                    bar[pos - 2] = "░"

                elapsed = time.monotonic() - self.started

                sys.stderr.write(
                    f"\r\033[2K{self.label}: "
                    f"|{''.join(bar)}| {elapsed:6.1f}s"
                )
                sys.stderr.flush()

                pos += direction

                if pos >= self.width - 1:
                    pos = self.width - 1
                    direction = -1
                elif pos <= 0:
                    pos = 0
                    direction = 1

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.stop.set()

        if self.thread is not None:
            self.thread.join()

        elapsed = time.monotonic() - self.started

        if sys.stderr.isatty():
            sys.stderr.write("\r\033[2K")

        if exc_type is None:
            print(
                f"{self.label}: done [{elapsed:.1f}s]",
                file=sys.stderr,
                flush=True,
            )
        else:
            print(
                f"{self.label}: failed [{elapsed:.1f}s]",
                file=sys.stderr,
                flush=True,
            )


def pbar(iterable, *, desc, unit):
    """Consistent terminal progress bars for deterministic phases."""
    return tqdm(
        iterable,
        desc=desc,
        unit=unit,
        dynamic_ncols=True,
        mininterval=0.1,
        smoothing=0.1,
        leave=True,
        disable=None,
    )


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

# Qwen's non-streaming call keeps the forced aligner and Qwen's own long-audio
# chunking behavior. Because the public call is blocking, use an indeterminate
# activity bar rather than a fabricated 0-100 percentage.
with Activity("Qwen: transcribing + aligning"):
    # Keep the complete result because `text` retains the ASR punctuation while
    # `time_stamps` contains the aligner's punctuation-stripped timed units.
    r = m.transcribe(
        audio=sys.argv[1],
        language=None,
        return_time_stamps=True,
    )[0]

a = list(r.time_stamps)

print("Qwen: detected language:", r.language, flush=True)
print(f"Qwen: aligned units: {len(a)}", flush=True)


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


def split_sentences(text):
    """Split at sentence-final punctuation while preserving that punctuation."""
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
sentences = split_sentences(r.text)

sentence_bar = pbar(
    sentences,
    desc="Qwen: mapping sentences",
    unit="sentence",
)

for sentence in sentence_bar:
    count = len(m.forced_aligner.aligner_processor.encode_timestamp(
        sentence,
        r.language,
    )[0])

    if count == 0:
        continue

    end = min(pos + count, len(a))
    items = a[pos:end]
    pos = end

    if items:
        groups.append((sentence, items))

    sentence_bar.set_postfix(
        mapped=len(groups),
        timed=f"{pos}/{len(a)}",
        refresh=False,
    )

# Preserve any residual aligned tail.
if pos < len(a):
    groups.append((" ".join(x.text for x in a[pos:]), a[pos:]))


def split_group(text, items):
    """
    Split a source sentence only when required by pause, duration or length.
    Sentence-final punctuation is restored on the final piece because Qwen's
    timestamp units themselves do not contain punctuation.
    """
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
    Split an overlong English translation and divide its source-aligned time
    interval proportionally by visible character count.
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


def balance_lines(text, width=LINE_WIDTH):
    """Balance one cue across one or two lines without discarding text."""
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

build_bar = pbar(
    groups,
    desc="Qwen: building source cues",
    unit="sentence",
)

for sentence, items in build_bar:
    source_cues.extend(split_group(sentence, items))
    build_bar.set_postfix(cues=len(source_cues), refresh=False)


print("Qwen: translating and finalizing subtitle cues...", flush=True)

cues = []

finalize_bar = pbar(
    source_cues,
    desc=(
        "Qwen: translating"
        if r.language != "English"
        else "Qwen: finalizing"
    ),
    unit="cue",
)

for text, items in finalize_bar:
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

    finalize_bar.set_postfix(output=len(cues), refresh=False)


# Balance lines before writing so formatting itself has an exact progress bar.
formatted_cues = []

format_bar = pbar(
    cues,
    desc="Qwen: balancing lines",
    unit="cue",
)

for text, start, end in format_bar:
    formatted_cues.append(
        (balance_lines(text), start, end)
    )


# Validate every final cue before writing it. This catches timing regressions
# without silently discarding subtitle text.
validated_cues = []

qa_bar = pbar(
    formatted_cues,
    desc="Qwen: validating cues",
    unit="cue",
)

previous_end = 0.0

for text, start, end in qa_bar:
    if not text.strip():
        raise ValueError("Qwen produced an empty subtitle cue.")

    if end < start:
        raise ValueError(
            f"Subtitle cue has negative duration: {start} -> {end}"
        )

    if start < previous_end - 0.001:
        raise ValueError(
            f"Subtitle cue overlaps the previous cue: {start} < {previous_end}"
        )

    validated_cues.append((text, start, end))
    previous_end = end


print(
    f"Qwen: writing {len(validated_cues)} subtitle cues...",
    flush=True,
)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    write_bar = pbar(
        validated_cues,
        desc="Qwen: writing SRT",
        unit="cue",
    )

    for n, (text, start, end) in enumerate(write_bar, 1):
        f.write(
            f"{n}\n"
            f"{ts(start)} --> {ts(end)}\n"
            f"{text}\n\n"
        )

print(
    f"Qwen: wrote {len(validated_cues)} subtitle cues.",
    flush=True,
)
PYQWEN
                    ;;


                whisperx)
                    status "Transcribing with WhisperX: $file ($file_no/$N)"

                    # WhisperX can use CPU everywhere, so start with a safe CPU
                    # configuration and replace it only when CUDA is confirmed.
                    WX_GPU=(--device cpu --compute_type float32)

                    if python3.12 -c \
                        'import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)' \
                        2>/dev/null
                    then
                        WX_GPU=(--device cuda --compute_type float16)
                    fi

                    # `--verbose True` prints useful transcript details while
                    # `--print_progress True` exposes WhisperX's progress updates.
                    whisperx \
                        --task translate \
                        --model large-v3 \
                        --batch_size 4 \
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

                    # stable-ts/faster-whisper downloads large-v3 automatically
                    # on first use when the model is not already cached.

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
                        --model large-v3 \
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