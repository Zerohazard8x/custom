#!/bin/bash

# Resolve companion scripts relative to this file so this script remains
# standalone when it is launched from another working directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Mirror all later stdout/stderr to the terminal and an append-only log.
exec > >(tee -a transcribe.log) 2>&1

# Make Python status/progress output appear immediately instead of waiting for
# stdout buffering to fill.
export PYTHONUNBUFFERED=1

# Prompt on exit only when an interactive terminal is actually available (only when `/dev/tty` is readable).
#
# `/dev/tty` is used instead of stdin because stdin may have been redirected by
# whatever launched the script.
# `-r` prevents `read` from interpreting backslashes.
#
# Installing this as an EXIT trap keeps the pause in one place and makes it run
# for normal completion as well as explicit `exit` calls elsewhere in the
# script.
#
# The test and `read` are kept inside the quoted trap body so they are evaluated
# when the script exits, not when the trap is initially registered.
trap '[[ -r /dev/tty ]] && read -r -p "Press Enter to close..." </dev/tty' EXIT

# Print each phase normally and, when stdout is a terminal (when /dev/tty is writable), also place it in the
# terminal/tab title so the current operation remains visible while output scrolls.
status() {
	# ANSI/OSC title sequence.
	#
	# Write directly to /dev/tty because stdout itself is piped through `tee`,
	# which means `[[ -t 1 ]]` would otherwise be false.
	[[ -w /dev/tty ]] &&
		printf '\033]0;%s\007' "$1" >/dev/tty 2>/dev/null

	# Add a leading newline so each major phase remains visually separated from
	# whatever output the previous command produced.
	#
	# `printf` is used instead of `echo` because the format and escape handling
	# are explicit and predictable.
	printf '\n== %s ==\n' "$1"
}

#################################
# Check core dependencies
#################################

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

# Keep FFmpeg informative without repeatedly printing its long version/build
# banner. `info` retains normal processing information while `-stats` keeps the
# familiar continuously updated progress line.
ffmpeg() {
	command ffmpeg -hide_banner -loglevel info -stats "$@"
}

#################################
# Detect transcription backends
#################################

# Build the model/backend menu dynamically.
status "Detecting transcription backends"

# Build the menu dynamically so the user sees only backends that are actually
# usable in the current environment.
BACKENDS=()

# Probe optional Demucs
# `&& ... || ...` deliberately converts exit status into Bash 1/0 flag
python3.12 -c 'import demucs' 2>/dev/null && DEMUCS=1 || DEMUCS=0

# Detect the PyTorch accelerator used by Demucs and the ordinary stable-ts path.
PT_KIND="$(python3.12 -c 'import torch; m=getattr(torch.backends,"mps",None); print("ROCm" if torch.cuda.is_available() and torch.version.hip else "CUDA" if torch.cuda.is_available() else "MPS" if m and m.is_available() else "CPU")' 2>/dev/null || echo CPU)"
case "$PT_KIND" in
CUDA | ROCm)
	PT_DEVICE=cuda
	;;
MPS)
	PT_DEVICE=mps

	# MPS still has occasional missing PyTorch kernels
	# allow an unsupported operation to fall back to CPU
	export PYTORCH_ENABLE_MPS_FALLBACK=1
	;;
*)
	PT_DEVICE=cpu
	;;
esac

# Demucs uses a torch.device internally and explicitly handles MPS in Hybrid
# Demucs, so the same PyTorch device can be used for its separation work.
DEMUCS_DEVICE="$PT_DEVICE"
DEMUCS_KIND="$PT_KIND"

# Prefer BS-RoFormer model
# `-l --list_format=json` verifies audio-separator knows the exact model before it is preferred
ROFORMER_MODEL=model_bs_roformer_ep_317_sdr_12.9755.ckpt
if command -v audio-separator >/dev/null &&
	audio-separator -l --list_format=json 2>/dev/null |
	grep -Fq "$ROFORMER_MODEL"; then
	ROFORMER=1
else
	ROFORMER=0
fi

# test CTranslate2 bc WhisperX's ASR model runs through CTranslate2
WX_KIND="$(python3.12 -c 'import ctranslate2,torch; assert torch.cuda.is_available() and ctranslate2.get_cuda_device_count(); print("ROCm" if torch.version.hip else "CUDA")' 2>/dev/null || echo CPU)"
[[ "$WX_KIND" == CPU ]] && WX_DEVICE=cpu || WX_DEVICE=cuda

# Qwen uses Transformers `device_map="auto"`
# asking Accelerate for its selected device therefore reports supported accelerator
QWEN_KIND="$(python3.12 -c 'import torch; from accelerate import Accelerator; d=Accelerator().device.type; print("ROCm" if d=="cuda" and torch.version.hip else d.upper())' 2>/dev/null || echo CPU)"

# stable-ts has a purpose-built MLX Whisper backend on Apple Silicon.
STABLE_ARGS=(--device "$PT_DEVICE")
STABLE_KIND="$PT_KIND"
if [[ "$PT_DEVICE" == mps ]] &&
	python3.12 -c 'import mlx_whisper' 2>/dev/null; then
	STABLE_ARGS=(-mlx)
	STABLE_KIND=MLX
fi

# Keep formatting in one helper because every menu row needs the same wording
accel() {
	[[ "$1" == CPU ]] && printf 'unavailable (CPU)' || printf 'available (%s)' "$1"
}

# Prefer WhisperX first when available.
# Demucs is optional
# `torch` is also checked because WhisperX depends on it later for device handling.
if python3.12 -c 'import whisperx,torch' 2>/dev/null; then
	BACKENDS+=(whisperx)
	echo "whisperx found"
fi

# Qwen requires its ASR package, Transformers, and Accelerate.
if python3.12 -c 'import qwen_asr,transformers,accelerate' 2>/dev/null; then
	BACKENDS+=(qwen)
	echo "qwen found"
fi

# stable-ts is exposed as a command-line program
# checking PATH is sufficient for this backend
if command -v stable-ts >/dev/null; then
	BACKENDS+=(stable-ts)
	echo "stable-ts found"
fi

# `${#BACKENDS[@]}` expands to the number of elements in the array.
# this guard executes the block only when no usable backend was detected.
# The block form keeps the error and exit together without adding an inverted
# multi-line `if` around a single condition.
((${#BACKENDS[@]})) || {
	echo "No transcription model is available."
	exit 1
}

#################################
# Count candidate videos
#################################

status "Counting videos"

# Count candidate files once so every later progress message can use the same
# stable total instead of rescanning the directory during each processing step.
N=0

for f in *; do
	# Process only MP4/MKV names and exclude preserved originals whose names
	# begin with `old_`.
	#
	# `=~` so one regular expression can cover both allowed extensions
	[[ "$f" =~ \.(mp4|mkv)$ && ! "$f" =~ ^old_ ]] && ((N++))
done

#################################
# Choose transcription backend
#################################

# Clear the terminal and move the cursor to the upper-left corner.
printf '\033[2J\033[H'

status "Choosing transcription backend"

echo "Transcription model"
echo "Videos: $N"

# Keep vocal-isolation status on this cleared screen.
if ((ROFORMER)); then
	echo "BS-RoFormer: available [acceleration $(accel "$PT_KIND")]"
else
	echo "BS-RoFormer: unavailable"
fi

# Keep Demucs status on this cleared screen
if ((DEMUCS)); then
	echo "Demucs: available [acceleration $(accel "$DEMUCS_KIND")]"
else
	echo "Demucs: unavailable"
fi

# `${!BACKENDS[@]}` expands to the array's indexes. Keeping the stored backend
# identifiers separate from their friendly names makes the later `case`
# statement simple while still presenting descriptive menu text.
for i in "${!BACKENDS[@]}"; do
	case "${BACKENDS[i]}" in
	qwen)
		name="Qwen3-ASR"
		acceleration="$(accel "$QWEN_KIND")"
		;;
	whisperx)
		name="WhisperX"
		acceleration="$(accel "$WX_KIND")"
		;;
	stable-ts)
		name="stable-ts"
		acceleration="$(accel "$STABLE_KIND")"
		;;
	esac

	# Menu numbers are one-based for humans even though Bash arrays are
	# zero-based, hence `i + 1`.
	printf '%d) %s [acceleration %s]\n' "$((i + 1))" "$name" "$acceleration"
done

# BACKENDS[0] represents the preferred available fallback
#
# array length is inserted into prompt dynamically so valid range always matches generated menu
printf 'Choose [1-%d] (auto in 5s): ' "${#BACKENDS[@]}"

# Initialize the variable explicitly so timeout/no-input handling below never
# depends on a value inherited from the environment.
choice=""

# Read a single character from the actual terminal and wait at most five seconds.
#
# `-r` prevents backslash processing.
# `-t 5` implements the five-second automatic selection timeout.
# `-n 1` means the user can simply press "1", "2", etc. without Enter.
# `</dev/tty` deliberately reads from the interactive terminal rather than
#     standard input, because the script might itself be launched through a
#     pipe or another redirected environment.
# `|| true` prevents a normal timeout from being treated as a fatal error.
[[ -r /dev/tty ]] && read -r -t 5 -n 1 choice </dev/tty || true

# `read -n 1` does not consume or print a newline, so explicitly print one before
# continuing with normal line-oriented output.
echo

# Accept the user's choice only when it is a valid positive menu number.
#
# The regex check happens before arithmetic use so arbitrary text is never
# treated as an array choice.
#
# Bash array indexing is zero-based, hence `choice - 1`.
if [[ "$choice" =~ ^[1-9]$ ]] && ((choice <= ${#BACKENDS[@]})); then
	ASR_BACKEND="${BACKENDS[choice - 1]}"
else
	# Timeout, blank input, unavailable `/dev/tty`, or invalid input selects the
	# first available backend.
	ASR_BACKEND="${BACKENDS[0]}"
fi

echo "Using: $ASR_BACKEND"

#################################
# Preferred vocal isolation
#################################

# Try the preferred separator in one helper because WhisperX and stable-ts need
# the same input contract. The function returns success only after the expected
# WAV exists, which lets each caller fall through to its existing Demucs path
# when audio-separator itself is installed but separation fails at runtime.
roformer_vocals() {
	wx_dir="old_${filename}.roformer"
	local roformer_audio="$wx_dir/vocals.wav"

	status "Isolating vocals with BS-RoFormer: $file ($file_no/$N)"

	# `-p` makes reruns tolerant of a directory left by an interrupted previous
	# attempt.
	mkdir -pv "$wx_dir"

	# `--single_stem Vocals` unused instrumental stem,
	# `--chunk_duration 300` uses five-minute split/process/merge path instead of duplicating Demucs code
	if audio-separator \
		"old_$file" \
		--model_filename "$ROFORMER_MODEL" \
		--output_format WAV \
		--output_dir "$wx_dir" \
		--single_stem Vocals \
		--chunk_duration 300 \
		--custom_output_names '{"Vocals":"vocals"}' &&
		[[ -f "$roformer_audio" ]]; then
		wx_audio="$roformer_audio"
		return 0
	fi

	echo "BS-RoFormer failed; trying the next available isolation method."
	rm -rfv "$wx_dir"
	wx_dir=""
	return 1
}

#################################
# Process video files
#################################

# Track the candidate-file position separately from the directory iteration so
# progress messages can use the previously calculated `$N` total.
file_no=0

# Iterate over the same ordinary entries used by the counting pass above.
for file in *; do
	# Process MP4/MKV files only.
	# Files beginning with old_ are skipped because those are originals that
	# this script has already renamed and preserved.
	if [[ "$file" =~ \.(mp4|mkv)$ && ! "$file" =~ ^old_ ]]; then
		# Increment only after confirming that this is a candidate video. That
		# keeps the progress numerator aligned with the earlier `$N` count.
		((file_no++))

		status "Checking: $file ($file_no/$N)"

		# Skip videos that already contain an English subtitle stream.
		#
		# `-v warning` shows warnings/errors without normal informational chatter
		# so stdout can remain machine-readable for `grep`.
		#
		# `-select_streams s` limits inspection to subtitle streams, while
		# `-show_entries stream_tags=language` asks only for their language tags.
		#
		# CSV output without the usual wrapper (`p=0`) leaves simple values such
		# as `eng`, which can be tested directly with `grep -q`.
		#
		# The pipeline succeeds when `grep` finds `eng`. The leading `!` inverts
		# that result
		if ! ffprobe \
			-v warning \
			-select_streams s \
			-show_entries stream_tags=language \
			-of csv=p=0 \
			"$file" |
			grep -q eng; then

			# Remove only the final extension.
			#
			# `${file%.*}` is parameter expansion rather than an external command,
			# so it preserves spaces and earlier dots in names such as
			# `episode.01.final.mp4`.
			filename="${file%.*}"

			# Preserve the original input before creating any replacement output.
			#
			# The `old_` prefix also prevents the preserved copy from being picked
			# up during future runs of the candidate-file loop.
			mv -fv "$file" "old_$file"

			# Qwen uses this 16 kHz mono WAV. The other backends operate on the
			# original program audio or their own separated audio instead.
			asr_audio="old_${filename}.asr.wav"

			# All backends ultimately produce this same SRT path, allowing the
			# muxing code below to be completely backend-independent.
			srtfile="old_${filename}.srt"

			# Removing stale copy here prevents English/stable-ts runs from accidentally muxing an old source track
			srcsrt="old_${filename}.source.srt"
			rm -f "$srcsrt"

			#################################
			# Transcription backend
			#################################

			case "$ASR_BACKEND" in
			qwen)
				#################################
				# Prepare speech audio for Qwen
				#################################

				status "Preparing audio: $file ($file_no/$N)"

				#  `-y` permits replacement of an existing temporary WAV.
				#  `-i` selects the preserved original as the source.
				#  `-vn` ignores video because only speech audio is required.
				#  `-ac 1` downmixes to mono.
				#  `-ar 16000` resamples to 16 kHz.
				#  `-c:a pcm_s16le` writes uncompressed signed 16-bit PCM.
				#
				# `|| exit 1` stops immediately if audio preparation fails
				ffmpeg \
					-y \
					-i "old_$file" \
					-vn \
					-ac 1 \
					-ar 16000 \
					-c:a pcm_s16le \
					"$asr_audio" || exit 1

				status "Transcribing with Qwen3-ASR: $file ($file_no/$N)"

				# Pass the temporary audio path and desired SRT path as ordinary
				# positional arguments to an inline Python program.
				#
				# `python3.12 -` tells Python to read its program from stdin. The
				# three filenames after `-` therefore become `sys.argv[1]` through
				# `sys.argv[3]`.
				#
				# The quoted heredoc delimiter (`<<'PYQWEN'`) is to prevent Bash from expanding `$`, backticks, or backslashes
				#
				# The failure guard is kept on this invocation rather than inside
				# Python so every backend reports failure to the surrounding Bash
				# control flow in the same way.
				python3.12 - "$asr_audio" "$srtfile" "$srcsrt" <<'PYQWEN' || exit 1
import sys

from qwen_asr import Qwen3ASRModel
from transformers import AutoModelForCausalLM, AutoTokenizer

# `flush=True` makes this potentially slow model-loading phase visible
# immediately even when Python's stdout is buffered by its environment.
print("Qwen: loading ASR + forced aligner...", flush=True)

# Load ASR and its forced aligner together so transcription and timestamp
# generation use the intended pair of Qwen models.
m = Qwen3ASRModel.from_pretrained(
    "Qwen/Qwen3-ASR-1.7B",
    dtype="auto",
    device_map="auto",
    forced_aligner="Qwen/Qwen3-ForcedAligner-0.6B",
    forced_aligner_kwargs={
        "dtype": "auto",
        "device_map": "auto",
    },
)

print("Qwen: transcribing and aligning audio...", flush=True)

# Keep the complete result because `text` retains the ASR punctuation while
# `time_stamps` contains the aligner's punctuation-stripped timed units.
#
# `language=None` for source-language detection.
# Timestamps are explicitly requested because the SRT writer below needs start
# and end times for every cue.
#
# `[0]` because this API returns a collection of results
r = m.transcribe(
    audio=sys.argv[1],
    language=None,
    return_time_stamps=True,
)[0]

print(f"Qwen: detected language: {r.language}", flush=True)

# Load the translation model only when the complete recording was not detected
# as English. A mixed value such as "Chinese,English" therefore still translates.
if r.language != "English":
    print("Qwen: loading English translation model...", flush=True)

    # Keep tokenizer and model loading together because they are two parts of
    # the same optional translation path.
    tok = AutoTokenizer.from_pretrained("Qwen/Qwen3-0.6B")

    lm = AutoModelForCausalLM.from_pretrained(
        "Qwen/Qwen3-0.6B",
        torch_dtype="auto",
        device_map="auto",
    )

    def tr(s):
        """Translate one source cue into concise, natural subtitle English."""

        # Give the model a deliberately narrow instruction because only the
        # translated subtitle text should be returned to the SRT writer.
        x = tok(
            "Translate to English. Output only the translation:\n" + s,
            return_tensors="pt",
        ).to(lm.device)

        # `**x` expands the tokenizer's mapping into the keyword arguments
        # expected by `generate()`.
        #
        # A finite generation limit prevents an unexpectedly verbose response
        # from growing without bound for a subtitle-sized input.
        y = lm.generate(
            **x,
            max_new_tokens=256,
        )

        # Decode only tokens generated after the original prompt.
        #
        # `x["input_ids"].shape[-1]` is the prompt token count, so slicing from
        # there prevents the instruction/source text from being copied into the
        # subtitle cue.
        return tok.decode(
            y[0][x["input_ids"].shape[-1]:],
            skip_special_tokens=True,
        ).strip()

def ts(x):
    """Convert floating-point seconds to SRT's HH:MM:SS,mmm format."""

    # Convert once to integer milliseconds so subsequent divmod operations avoid
    # accumulating floating-point formatting errors.
    #
    # `max(0.0, x)` prevents a small negative timestamp from producing an invalid
    # negative SRT time.
    #
    # `round()` is applied before `int()` so values are rounded to the nearest
    # millisecond rather than always truncated downward.
    ms = int(round(max(0.0, x) * 1000))

    # Repeated `divmod()` calls naturally split one millisecond total into the
    # hierarchical hour/minute/second/remainder fields SRT expects.
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)

    # Zero padding is part of the conventional fixed-width SRT timestamp shape.
    return f"{h:02}:{m:02}:{s:02},{ms:03}"

print("Qwen: writing subtitles...", flush=True)

# Write the native cues only for non-English input.
if r.language != "English":
    # `sys.argv[3]` is kept beside the English path so both outputs share the
    # same basename while remaining separate files for the later mux step.
    with open(sys.argv[3], "w", encoding="utf-8") as f:
        for n, x in enumerate(r.time_stamps.items, 1):
            f.write(
                f"{n}\n"
                f"{ts(x.start_time)} --> {ts(x.end_time)}\n"
                f"{x.text}\n\n"
            )

# UTF-8 because subtitle text may contain arbitrary Unicode
with open(sys.argv[2], "w", encoding="utf-8") as f:
    # SRT cue numbering starts at 1, hence the explicit starting value passed
    # to `enumerate()`.
    for n, x in enumerate(r.time_stamps.items, 1):
        # Translate each cue only when the recording was not classified as
        # entirely English; otherwise preserve the recognized English text.
        text = tr(x.text) if r.language != "English" else x.text

        # Adjacent f-strings inside parentheses are concatenated by Python,
        # letting the SRT record remain visually split into its logical lines
        # without explicit `+` operators.
        #
        # The final extra newline leaves the blank separator required between
        # ordinary SRT cues.
        f.write(
            f"{n}\n"
            f"{ts(x.start_time)} --> {ts(x.end_time)}\n"
            f"{text}\n\n"
        )

print("Qwen: subtitles written.", flush=True)
PYQWEN
				;;

			whisperx)
				#################################
				# Optionally isolate vocals for WhisperX
				#################################

				# Default to the preserved source
				wx_audio="old_$file"

				if ((ROFORMER)) && roformer_vocals; then
					:
				elif ((DEMUCS)); then
					# directory and segmented-file pattern share the same base so
					# all temporary WhisperX/Demucs artifacts remain grouped together.
					wx_dir="old_${filename}.demucs"
					wx_mix="$wx_dir/%03d.wav"

					status "Isolating vocals for WhisperX: $file ($file_no/$N)"

					# `-p` also makes reruns tolerant of a directory left by an
					# interrupted previous attempt.
					mkdir -pv "$wx_dir"

					# Split the source audio into five-minute PCM WAV segments before
					# Demucs processing.
					#
					# Segmenting first limits the size of each individual input sent
					# through the separation stage.
					#
					# `-f segment -segment_time 300` asks FFmpeg's segment muxer to
					# create consecutive 300-second files using the `%03d` filename
					# pattern defined above.
					ffmpeg \
						-y \
						-i "old_$file" \
						-vn \
						-c:a pcm_s16le \
						-f segment \
						-segment_time 300 \
						"$wx_mix" || exit 1

					# Two-stem mode extracts vocals against the remainder of the program mix.
					#
					# `--other-method none` avoids requesting additional processing of
					# the non-vocal stem.
					#
					# `-d` is explicit here because Demucs otherwise only auto-selects
					# CUDA/CPU and would miss an available MPS device.
					#
					# `-v` enables Demucs' useful verbose/progress output.
					#
					# Shell expansion of `"$wx_dir"/*.wav` supplies all segmented WAV
					# inputs to the same Demucs invocation.
					# The quoted directory part protects spaces
					python3.12 -m demucs \
						-d "$DEMUCS_DEVICE" \
						--two-stems vocals \
						--other-method none \
						-v \
						-o "$wx_dir" \
						"$wx_dir"/*.wav || exit 1

					# Reassemble the separated vocal segments in their original order.
					#
					# The subshell changes into `wx_dir` to keep paths written into the concat list short and relative without changing the parent script's directory.
					#
					# `printf` creates one FFmpeg concat-demuxer `file` entry per
					# separated stem. `-c copy` then joins compatible WAV segments
					# without another encode.
					(
						cd "$wx_dir" &&
							printf "file '%s'\n" htdemucs/*/vocals.wav >list &&
							ffmpeg \
								-f concat \
								-i list \
								-c copy \
								vocals.wav
					) || exit 1

					# Give final track a descriptive variable
					wx_audio="$wx_dir/vocals.wav"

					# Check final stem
					[[ -f "$wx_audio" ]] || {
						echo "Demucs did not create the expected vocals stem."
						exit 1
					}
				else
					echo "Vocal isolation unavailable; WhisperX will use source audio."
				fi

				status "Transcribing with WhisperX: $file ($file_no/$N)"

				#################################
				# Select WhisperX compute device
				#################################

				# bc CTranslate2 calls both CUDA and ROCm/HIP GPU execution `cuda`
				WX_GPU=(--device "$WX_DEVICE")

				echo "WhisperX device: ${WX_GPU[1]} ($WX_KIND)"

				#################################
				# Transcribe with WhisperX
				#################################

				# `PYTHONIOENCODING=utf-8` keeps transcript/progress output Unicode-safe
				#
				# positional arguments are expanded from the `WX_GPU` array.
				#   argv[1] = audio filename
				#   argv[2] = --device
				#   argv[3] = cpu/cuda
				#   argv[4] = source-language SRT path
				#
				# quoting the heredoc marker prevents Bash expansion inside the Python source
				PYTHONIOENCODING=utf-8 python3.12 - "$wx_audio" "${WX_GPU[@]}" "$srcsrt" <<'PYWHISPERX' || exit 1
import sys
import whisperx
from whisperx.utils import get_writer

print(
    f"WhisperX: loading large-v3 model on {sys.argv[3]}...",
    flush=True,
)

# Load WhisperX using the device selected by the Bash wrapper.
m = whisperx.load_model(
    "large-v3",
    sys.argv[3],
    vad_options={
        "vad_onset": 0.400,
        "vad_offset": 0.250,
    },
)

print("WhisperX: loading transcription audio...", flush=True)

# Decode whichever input the Bash wrapper selected. This is normally the
# separated vocal stem when isolation exists and the preserved source otherwise.
a = whisperx.load_audio(sys.argv[1])

print("WhisperX: transcribing source language...", flush=True)

# transcribe in the source language
# obtains language detection result before the later English-translation pass
source = m.transcribe(
    a,
    task="transcribe",
	# chunk_size=7, # comment out for smaller subtitles
    verbose=True,
    print_progress=True,
)

# Store the detected language separately because the translation call below still needs it
language = source["language"]

print(f"WhisperX: detected language: {language}", flush=True)

# Preserve the source transcript before translation only when it differs from English.
if language != "en":
    # The writer derives its basename from this argument.
	# Passing requested SRT path therefore yields basename and `.srt` extension
    get_writer("srt", ".")(
        source,
        sys.argv[4],
        {
            "highlight_words": False,
            "max_line_count": None,
            "max_line_width": None,
        },
    )

# Use ordinary translation behavior unless the alignment-model availability
# check below indicates that this language needs the fallback chunk setting.
split = {}

print("WhisperX: checking alignment model...", flush=True)

# Test whether WhisperX can load an alignment model for the detected language.
#
# If alignment-model loading raises `ValueError`, use an eight-second chunk
# length for the later translation call as the existing fallback behavior.
try:
    whisperx.load_align_model(
        language_code=language,
        device=sys.argv[3],
    )
except ValueError:
    split = {
        "chunk_length": 8,
    }

print("WhisperX: translating transcript to English...", flush=True)

# Run Whisper's translation task only for non-English source audio.
# Reuse the first transcription for English so ASR never runs twice.
#
# `**split` keeps the normal call free of a chunk override while still allowing
# the fallback dictionary above to inject `chunk_length=8`
if language == "en":
    native = source["segments"]
else:
    native, _ = m.model.transcribe(
    a,
    language=language,
    task="translate",

    # for long recordings
	# usually set by default (but not here)
    condition_on_previous_text=False,

    # Don't let silence/music become translation input
	# usually set by default (but not here)
    vad_filter=True,

    **split,
)

print("WhisperX: preparing SRT subtitles...", flush=True)

# Convert the backend's translated segment objects into the plain dictionary
# structure expected by WhisperX's SRT writer.
#
# List comprehension is used because this transformation is one-to-one: every translated segment contributes exactly one output segment.
r = {
    "segments": [
        {
            "text": x["text"] if isinstance(x, dict) else x.text,
            "start": x["start"] if isinstance(x, dict) else x.start,
            "end": x["end"] if isinstance(x, dict) else x.end,
        }
        for x in native
    ],
    "language": "en",
}

# Write directly to SRT.
#
# `"."` tells the writer to place its output in the current directory.
get_writer("srt", ".")(
    r,
    sys.argv[1],
    {
        "highlight_words": False,
        "max_line_count": None,
        "max_line_width": None,
    },
)

print("WhisperX: subtitles written.", flush=True)
PYWHISPERX

				wx_srt="${wx_audio##*/}"
				wx_srt="${wx_srt%.*}.srt"

				# Rename to common filenam
				mv -fv "$wx_srt" "$srtfile" || exit 1

				;;

			stable-ts)
				# No source SRT is created here because `--task transcribe` would require
				# another Whisper decode in addition to the existing translation pass.

				#################################
				# Transcribe with stable-ts
				#################################

				# stable-ts asks Whisper to translate recognized speech into English.
				#
				# `-v 1` enables its progress bar
				# `--task translate` requests English translation.
				# `$STABLE_ARGS` selects MLX when installed, otherwise it selects PyTorch device.
				# BS-RoFormer is preferred externally when available; the original
				# stable-ts Demucs denoiser remains the fallback.
				# `-o "$srtfile"` gives this backend the same output contract
				#     used by Qwen and WhisperX.
				wx_audio="old_$file"
				stable_ts_demucs=()
				if ((ROFORMER)) && roformer_vocals; then
					:
				elif ((DEMUCS)); then
					stable_ts_demucs=(
						--denoiser demucs
						--denoiser_option "device=$DEMUCS_DEVICE"
					)
				else
					echo "Vocal isolation unavailable; stable-ts will use source audio."
				fi

				status "Transcribing with stable-ts: $file ($file_no/$N)"

				stable-ts \
					-v 1 \
					--task translate \
					"${STABLE_ARGS[@]}" \
					"${stable_ts_demucs[@]}" \
					"$wx_audio" \
					-o "$srtfile" || exit 1
				;;
			esac

			#################################
			# Mux subtitles into final MKV
			#################################

			# Refuse to mux anything if the selected backend did not actually
			# create the expected subtitle file.
			[[ -f "$srtfile" ]] || exit 1

			# Post-processing is optional so this transcription script can still be
			# copied and run by itself. The companion independently discovers which
			# of ffsubsync and seconv are available.
			postprocess="$SCRIPT_DIR/postprocess-subtitles.sh"
			if [[ -f "$postprocess" ]]; then
				status "Post-processing subtitles: $file ($file_no/$N)"
				postprocess_args=("${wx_audio:-old_$file}" "$srtfile")
				# Pass the source SRT only when this backend produced one so ffsubsync can
				# synchronize both tracks while seconv still treats the first SRT as English.
				[[ -f "$srcsrt" ]] && postprocess_args+=("$srcsrt")
				# Qwen has already forced-aligned its timestamps, so retain them while
				# still allowing seconv to clean and reflow its subtitle text.
				[[ "$ASR_BACKEND" == qwen ]] && postprocess_args=("${postprocess_args[@]}")
				bash "$postprocess" "${postprocess_args[@]}" ||
					echo "Subtitle post-processing failed; using the last valid subtitles."
			else
				echo "postprocess-subtitles.sh not found; using generated subtitles."
			fi

			# Remove the temporary separated stems only when a backend actually
			# created a separation directory. Demucs used internally by stable-ts
			# does not create one here.
			[[ -n "${wx_dir:-}" ]] &&
				rm -rfv "$wx_dir"

			status "Muxing subtitles: $file ($file_no/$N)"

			# Empty arrays are intentional because quoted `${array[@]}` expands to no
			# arguments, letting one FFmpeg command handle backends with or without a
			# source SRT without duplicating the whole mux command.
			srcin=()
			srcmap=()
			if [[ -f "$srcsrt" ]]; then
				srcin=(-i "$srcsrt")
				srcmap=(-map 2:0 -metadata:s:s:1 title=Original)
			fi

			# so the resulting file contains:
			#   - the first video stream from input 0;
			#   - any audio streams from input 0;
			#   - the generated English subtitle stream from input 1;
			#   - the source-language subtitle stream from input 2
			#
			# `0:a?` so a source without audio does not cause the entire mux operation to fail merely because no matching audio stream exists.
			if ffmpeg \
				-i "old_$file" \
				-i "$srtfile" \
				"${srcin[@]}" \
				-map 0:v:0 \
				-map 0:a? \
				-map 1:0 \
				"${srcmap[@]}" \
				-c copy \
				-metadata:s:s:0 language=eng \
				"${filename}.mkv"; then
				# Remove temporary transcription/audio files only after the
				# final MKV has been created successfully.
				# The preserved `old_...` original is intentionally retained.
				rm -fv "$asr_audio"
				status "Finished: $file ($file_no/$N)"
			fi
		fi
	fi
done

status "All done ($N videos checked)"