#!/bin/bash

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
#
# The order in which entries are appended also defines automatic preference:
# when the user does not choose a backend, element 0 becomes the fallback.
BACKENDS=()

# Prefer WhisperX first when available.
# Demucs is required because this workflow isolates vocals before passing the
# audio to WhisperX.
# `torch` is also checked because WhisperX depends on it later for CUDA detection.
if python3.12 -c 'import whisperx,torch,demucs' 2>/dev/null; then
	BACKENDS+=(whisperx)
	echo "whisperx found"
fi

# Qwen requires both its ASR package and Transformers.
# Transformers is needed only for non-English recordings
if python3.12 -c 'import qwen_asr,transformers' 2>/dev/null; then
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

# `${!BACKENDS[@]}` expands to the array's indexes. Keeping the stored backend
# identifiers separate from their friendly names makes the later `case`
# statement simple while still presenting descriptive menu text.
for i in "${!BACKENDS[@]}"; do
	case "${BACKENDS[i]}" in
	qwen)
		name="Qwen3-ASR"
		;;
	whisperx)
		name="WhisperX"
		;;
	stable-ts)
		name="stable-ts"
		;;
	esac

	# Menu numbers are one-based for humans even though Bash arrays are
	# zero-based, hence `i + 1`.
	printf '%d) %s\n' "$((i + 1))" "$name"
done

# BACKENDS[0] represents the preferred available fallback because backends were
# appended above in preference order.
#
# The array length is inserted into the prompt dynamically so the displayed
# valid range always matches the menu that was actually generated.
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
				# two filenames after `-` therefore become `sys.argv[1]` and
				# `sys.argv[2]`.
				#
				# The quoted heredoc delimiter (`<<'PYQWEN'`) is to prevent Bash from expanding `$`, backticks, or backslashes
				#
				# The failure guard is kept on this invocation rather than inside
				# Python so every backend reports failure to the surrounding Bash
				# control flow in the same way.
				python3.12 - "$asr_audio" "$srtfile" <<'PYQWEN' || exit 1
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
				# Isolate vocals for WhisperX
				#################################

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
				# `-v` enables Demucs' useful verbose/progress output.
				#
				# Shell expansion of `"$wx_dir"/*.wav` supplies all segmented WAV
				# inputs to the same Demucs invocation. The quoted directory part
				# still protects spaces in the generated working-directory name.
				python3.12 -m demucs \
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
				# This keeps the preceding concat command expressed relative to its temporary working directory.
				wx_audio="$wx_dir/vocals.wav"

				# Check final stem
				[[ -f "$wx_audio" ]] || {
					echo "Demucs did not create the expected vocals stem."
					exit 1
				}

				status "Transcribing with WhisperX: $file ($file_no/$N)"

				#################################
				# Select WhisperX compute device
				#################################

				# Start with CPU configuration
				#
				# Bash array used so each future command-line argument remains a separate shell word when expanded.
				WX_GPU=(--device cpu)

				# Switch to CUDA only when CUDA is available.
				# Python command communicates the Boolean result through exit status
				if python3.12 -c \
					'import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)' \
					2>/dev/null; then
					WX_GPU=(--device cuda)
				fi

				echo "WhisperX device: ${WX_GPU[1]}"

				#################################
				# Transcribe with WhisperX
				#################################

				# `PYTHONIOENCODING=utf-8` keeps transcript/progress output Unicode-safe
				#
				# positional arguments are expanded from the `WX_GPU` array.
				#   argv[1] = audio filename
				#   argv[2] = --device
				#   argv[3] = cpu/cuda
				#
				# quoting the heredoc marker prevents Bash expansion inside the Python source
				PYTHONIOENCODING=utf-8 python3.12 - "$wx_audio" "${WX_GPU[@]}" <<'PYWHISPERX' || exit 1
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
)

print("WhisperX: loading isolated vocal audio...", flush=True)

# Decode the isolated vocal WAV into the representation expected by WhisperX.
a = whisperx.load_audio(sys.argv[1])

print("WhisperX: transcribing source language...", flush=True)

# transcribe in the source language
# obtains language detection result before the later English-translation pass
source = m.transcribe(
    a,
    task="transcribe",
    verbose=True,
    print_progress=True,
)

# Store the detected language separately because the translation call below still needs it
language = source["language"]

print(f"WhisperX: detected language: {language}", flush=True)

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

# Run Whisper's translation task after source-language detection.
#
# `**split` keeps the normal call free of a chunk override while still allowing
# the fallback dictionary above to inject `chunk_length=8`
native, _ = m.model.transcribe(
    a,
    language=language,
    task="translate",
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
            "text": x.text,
            "start": x.start,
            "end": x.end,
        }
        for x in native
    ],
    "language": "en",
}

# Write directly to SRT.
#
# `"."` tells the writer to place its output in the current directory. The Bash
# code immediately after this heredoc knows the resulting name and renames it to
# the common backend-independent `$srtfile` path.
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

				# WhisperX names its output after the isolated WAV input.
				# Rename it to the common filename expected below.
				mv -fv "vocals.srt" "$srtfile" || exit 1

				# Remove the temporary full-quality mix and separated stems.
				rm -rfv "$wx_mix" "$wx_dir"
				;;

			stable-ts)
				#################################
				# Transcribe with stable-ts
				#################################

				status "Transcribing with stable-ts: $file ($file_no/$N)"

				# stable-ts asks Whisper to translate recognized speech into English.
				#
				# `-v 1` enables its progress bar
				# `--task translate` requests English translation.
				# `--denoiser demucs` requests Demucs preprocessing.
				# `-o "$srtfile"` gives this backend the same output contract
				#     used by Qwen and WhisperX.
				stable-ts \
					-v 1 \
					--task translate \
					--denoiser demucs \
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

			# so the resulting file contains:
			#   - the first video stream from input 0;
			#   - any audio streams from input 0;
			#   - the generated subtitle stream from input 1.
			#
			# `0:a?` so a source without audio does not cause the entire mux operation to fail merely because no matching audio stream exists.
			if ffmpeg \
				-i "old_$file" \
				-i "$srtfile" \
				-map 0:v:0 \
				-map 0:a? \
				-map 1:0 \
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