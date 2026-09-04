#!/usr/bin/env bash

# Synchronize supplied SRTs, clean/reflow the first (English) subtitle,
# then resegment it by sentence, perform a conservative final synchronization,
# and lint the result.

# Usage
# ./postprocess-subtitles.sh video.mkv english.srt source.srt
# ./postprocess-subtitles.sh video.mkv
set -u

skip_sync=false
if [[ "${1:-}" == --skip-sync ]]; then
	skip_sync=true
	shift
fi

if (($# < 2)); then
	exit 2
fi

media=$1
srt=${2:-}

# Shift MEDIA away.
shift

if [[ ! -f "$media" ]]; then
	printf 'Error: media file not found: %s\n' "$media" >&2
	exit 1
fi

for subtitle; do
	if [[ ! -f "$subtitle" ]]; then
		printf 'Error: subtitle file not found: %s\n' "$subtitle" >&2
		exit 1
	fi
done

workdir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-postprocess.XXXXXX") || exit 1

embedded=false
if [[ -z "$srt" ]]; then
	embedded=true
	srt="$workdir/embedded.srt"

	if ! command -v ffmpeg >/dev/null 2>&1; then
		printf 'Error: ffmpeg is required for embedded subtitles.\n' >&2
		exit 1
	fi

	if ! ffmpeg -y -i "$media" -map 0:s:0 "$srt"; then
		printf 'Error: could not extract the first subtitle stream as SRT.\n' >&2
		exit 1
	fi

	set -- "$srt"
fi

cleanup() {
	rm -rf -- "$workdir"
}

trap cleanup EXIT HUP INT TERM

final_sync_max_offset=2


# ---------------------------------------------------------------------------
# 1. Initial synchronization
# ---------------------------------------------------------------------------

if [[ "$skip_sync" == false ]]; then
	if command -v ffsubsync >/dev/null 2>&1; then
		printf '\n[1/5] Initial subtitle synchronization\n'
		# One ffsubsync call shares its reference-audio extraction across every
		# input. `--overwrite-input` is required when `-i` names multiple SRTs.
		if ! ffsubsync "$media" \
			-i "$@" \
			--overwrite-input \
			--skip-sync-on-low-quality \
			--quality-max-offset-seconds 10; then

			printf 'Initial ffsubsync pass failed; continuing with the current timings.\n' >&2
		fi
	else
		printf 'ffsubsync not found; retaining the current timings.\n' >&2
	fi
else
	printf '\n[1/5] Synchronization skipped by --skip-sync\n'
fi


# ---------------------------------------------------------------------------
# 2. English subtitle cleanup and sentence-aware line-break placement
#
# The custom XML comes after `--balance-lines` because it is allowed to
# override a merely geometric/balanced newline when an existing sentence
# boundary gives a more natural reading break.
# ---------------------------------------------------------------------------

printf '\n[2/5] Clean and reflow English subtitles\n'

if ! command -v seconv >/dev/null 2>&1; then
	printf 'Error: seconv is required for the cleanup stage.\n' >&2
	exit 1
fi

main="$workdir/main.srt"
sentence_aware="$workdir/sentence-aware.srt"
cue_aware="$workdir/cue-aware.srt"
final="$workdir/final.srt"
rules="$workdir/sentence-aware-line-break-fixes.xml"

# The quoted heredoc delimiter (`<<'XML'`) prevents Bash from interpreting `$1`, `$2`, and `$3` before Subtitle Edit receives the XML.
cat >"$rules" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<MultipleSearchAndReplaceGroups>
  <Group>
	<Name>Sentence-aware line-break fixes</Name>
		<IsActive>true</IsActive>
	<Rules>
	  <Rule>
		<Active>true</Active>
		<FindWhat>^(.+[.!?…]["'”’)]?) +([^.!?…\n]+)\n(.+)$</FindWhat>
		<ReplaceWith>$1\n$2 $3</ReplaceWith>
		<SearchType>RegularExpression</SearchType>
	  </Rule>
	  <Rule>
		<Active>true</Active>
		<FindWhat>^(.+[^.!?…"'”’)])\n([^.!?…]*[.!?…]["'”’)]?)\s+(.+)$</FindWhat>
		<ReplaceWith>$1 $2\n$3</ReplaceWith>
		<SearchType>RegularExpression</SearchType>
	  </Rule>
	</Rules>
  </Group>
</MultipleSearchAndReplaceGroups>
XML

if ! seconv "$srt" subrip \
	--merge-short-lines \
	--split-long-lines \
	--balance-lines \
	--fix-common-errors-rules:"Fix3PlusLines,FixEmptyLines,FixInvalidItalicTags,FixMissingSpaces,FixUnneededSpaces,NormalizeStrings,FixShortLines" \
	--output-folder:"$workdir" \
	--output-filename:"${main##*/}" \
	--overwrite; then

	printf 'Error: initial seconv cleanup failed.\n' >&2
	exit 1
fi

printf '\n[line breaks] Apply sentence-aware newline fixes\n'

if ! seconv "$main" subrip \
	--multiple-replace:"$rules" \
	--output-folder:"$workdir" \
	--output-filename:"${sentence_aware##*/}" \
	--overwrite; then

	printf 'Error: sentence-aware line-break processing failed.\n' >&2
	exit 1
fi


# ---------------------------------------------------------------------------
# 3. Cross-cue sentence resegmentation
#
# This stage must follow text cleanup because it relies on normalized spacing
# and punctuation. It must precede timing cleanup because splitting a timed cue
# can create tiny gaps/overlaps that the existing seconv pass should normalize.
#
# `python - INPUT OUTPUT <<'PY'` runs the program from standard input while
# passing the two SRT paths as argv[1] and argv[2]. The quoted `PY` delimiter
# prevents Bash from expanding Python `$`-like or backslash syntax.
# ---------------------------------------------------------------------------

printf '\n[3/5] Resegment English cues by sentence\n'

if ! command -v python >/dev/null 2>&1; then
	printf 'Error: python is required for cross-cue sentence resegmentation.\n' >&2
	exit 1
fi

if ! python - "$sentence_aware" "$cue_aware" <<'PY'
import re
import sys

src, dst = sys.argv[1], sys.argv[2]

# Adjacent cues may be joined while looking for a sentence boundary, but these
# caps stop a long pause or an exceptionally long sentence becoming one huge
# subtitle. Four visible characters keeps "Yes." standalone while allowing a
# tiny response such as "No." to remain attached to a neighbouring sentence.
MAX_JOIN_GAP_MS = 1200
MAX_GROUP_CHARS = 140
MAX_GROUP_MS = 10000
MIN_STANDALONE_CHARS = 4

time_re = re.compile(
	r'^(\d{2}):(\d{2}):(\d{2}),(\d{3})\s+-->\s+'
	r'(\d{2}):(\d{2}):(\d{2}),(\d{3})(?:\s+.*)?$'
)
tag_re = re.compile(r'<[^>]+>')
style_tag_re = re.compile(r'<(/?)(i|b|u)>', re.I)
boundary_re = re.compile(
	r'''[.!?…]["'”’)]*(?:</(?i:i|b|u)>)*'''
	r'''(?=(?:\s+(?:<(?i:i|b|u)>)*["'“‘(]*[A-Z0-9])|$)'''
)
abbreviations = (
	'mr.', 'mrs.', 'ms.', 'dr.', 'prof.', 'sr.', 'jr.', 'st.',
	'vs.', 'etc.', 'e.g.', 'i.e.', 'a.m.', 'p.m.', 'no.', 'fig.'
)

def to_ms(parts):
	h, m, s, ms = map(int, parts)
	return ((h * 60 + m) * 60 + s) * 1000 + ms

def stamp(value):
	value = max(0, int(round(value)))
	h, rem = divmod(value, 3600000)
	m, rem = divmod(rem, 60000)
	s, ms = divmod(rem, 1000)
	return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'

def visible(text):
	return tag_re.sub('', text)

def normalized(text):
	text = re.sub(r'[ \t]+', ' ', text)
	return re.sub(r' *\n *', '\n', text).strip()

def starts_new_speaker(text):
	return visible(text).lstrip().startswith(('-', '–', '—', '♪', '♫'))

def is_abbreviation(text, end):
	prefix = visible(text[:end]).rstrip(' "\'”’)')
	low = prefix.lower()
	if any(low.endswith(item) for item in abbreviations):
		return True
	return re.search(r'(?:\b[A-Za-z]\.){2,}$', prefix) is not None

def sentence_ends(text):
	return [
		match.end()
		for match in boundary_re.finditer(text)
		if not is_abbreviation(text, match.end())
	]

def active_styles(text, pos):
	stack = []
	for match in style_tag_re.finditer(text, 0, pos):
		name = match.group(2).lower()
		if match.group(1):
			for i in range(len(stack) - 1, -1, -1):
				if stack[i] == name:
					del stack[i]
					break
		else:
			stack.append(name)
	return stack

def parse(path):
	data = open(path, encoding='utf-8-sig').read().replace('\r\n', '\n')
	cues = []
	for block in re.split(r'\n{2,}', data.strip()):
		lines = block.splitlines()
		if len(lines) < 3:
			continue
		match = time_re.match(lines[1].strip())
		if not match:
			raise SystemExit(f'Cannot parse SRT time line: {lines[1]!r}')
		cues.append({
			'start': to_ms(match.groups()[:4]),
			'end': to_ms(match.groups()[4:]),
			'text': normalized('\n'.join(lines[2:])),
		})
	return cues

def groups(cues):
	group = []
	chars = 0
	for cue in cues:
		cue_chars = len(visible(cue['text']))
		if group:
			gap = cue['start'] - group[-1]['end']
			duration = cue['end'] - group[0]['start']
			if (
				gap > MAX_JOIN_GAP_MS
				or starts_new_speaker(cue['text'])
				or chars + 1 + cue_chars > MAX_GROUP_CHARS
				or duration > MAX_GROUP_MS
			):
				yield group
				group = []
				chars = 0
		group.append(cue)
		chars += (1 if chars else 0) + cue_chars
	if group:
		yield group

def build_group(group):
	text = ''
	spans = []
	for cue in group:
		if text:
			text += ' '
		start = len(text)
		chunk = cue['text']
		text += chunk
		spans.append((start, len(text), cue, chunk))
	return text, spans

def time_at(spans, pos):
	for start, end, cue, chunk in spans:
		if start <= pos <= end:
			local = min(max(pos - start, 0), len(chunk))
			total = max(1, len(visible(chunk)))
			done = len(visible(chunk[:local]))
			return cue['start'] + (cue['end'] - cue['start']) * done / total
	return spans[-1][2]['end']

def segments(text):
	cuts = sentence_ends(text)
	result = []
	start = 0
	for end in cuts:
		while start < end and text[start].isspace():
			start += 1
		if start < end:
			result.append([start, end])
		start = end
	while start < len(text) and text[start].isspace():
		start += 1
	if start < len(text):
		result.append([start, len(text)])

	i = 0
	while i < len(result) and len(result) > 1:
		start, end = result[i]
		if len(visible(text[start:end]).strip()) < MIN_STANDALONE_CHARS:
			if i + 1 < len(result):
				result[i:i + 2] = [[start, result[i + 1][1]]]
			else:
				result[i - 1][1] = end
				result.pop()
				i -= 1
		else:
			i += 1
	return result

def styled_slice(text, start, end):
	before = active_styles(text, start)
	after = active_styles(text, end)
	raw = text[start:end].strip()
	return (
		''.join(f'<{name}>' for name in before)
		+ raw
		+ ''.join(f'</{name}>' for name in reversed(after))
	)

cues = parse(src)
out = []
for group in groups(cues):
	text, spans = build_group(group)
	for start, end in segments(text):
		begin = time_at(spans, start)
		finish = time_at(spans, end)
		if finish <= begin:
			finish = begin + 1
		out.append((begin, finish, styled_slice(text, start, end)))

with open(dst, 'w', encoding='utf-8', newline='\n') as output:
	for number, (start, end, text) in enumerate(out, 1):
		output.write(f'{number}\n{stamp(start)} --> {stamp(end)}\n{text}\n\n')
PY
then
	printf 'Error: cross-cue sentence resegmentation failed.\n' >&2
	exit 1
fi


# ---------------------------------------------------------------------------
# 4. Timing cleanup
# ---------------------------------------------------------------------------

if ! seconv "$cue_aware" subrip \
	--split-long-lines \
	--balance-lines \
	--fix-common-errors-rules:"FixOverlappingDisplayTimes,FixInvalidItalicTags" \
	--apply-min-gap:24 \
	--apply-duration-limits \
	--output-folder:"$workdir" \
	--output-filename:"${final##*/}" \
	--overwrite; then

	printf 'Error: final seconv timing cleanup failed.\n' >&2
	exit 1
fi

# Do not replace the user's English subtitle until every cleanup stage above
# has completed successfully.
mv -f -- "$final" "$srt"


# ---------------------------------------------------------------------------
# 5. Conservative final ffsubsync pass
#
# `--max-offset-seconds 2` means the second pass may only look for a small global correction.
#
# If the command fails, backup pre-final-sync SRT is restored.
# ---------------------------------------------------------------------------

if [[ "$skip_sync" == false ]]; then
	printf '\n[4/5] Conservative final synchronization\n'

	if command -v ffsubsync >/dev/null 2>&1; then
		pre_final_sync="$workdir/pre-final-sync.srt"

		if ! cp -p -- "$srt" "$pre_final_sync"; then
			printf 'Error: could not create final-sync safety copy.\n' >&2
			exit 1
		fi

		if ffsubsync "$media" \
			-i "$srt" \
			--overwrite-input \
			--no-fix-framerate \
			--max-offset-seconds "$final_sync_max_offset" \
			--skip-sync-on-low-quality \
			--quality-max-offset-seconds "$final_sync_max_offset"; then

			printf 'Final synchronization completed.\n'
		else
			printf 'Final ffsubsync pass failed; restoring pre-sync timings.\n' >&2

			if ! cp -p -- "$pre_final_sync" "$srt"; then
				printf 'Error: could not restore final-sync safety copy.\n' >&2
				exit 1
			fi
		fi
	else
		printf 'ffsubsync not found; final synchronization skipped.\n' >&2
	fi
else
	printf '\n[4/5] Final synchronization skipped by --skip-sync\n'
fi


# ---------------------------------------------------------------------------
# Final lint
# ---------------------------------------------------------------------------

printf '\n[5/5] Validate final subtitle\n'

if seconv lint "$srt"; then
	printf 'Lint: no reported problems.\n'
else
	printf 'Lint found items in the final subtitle.\n' >&2
fi

if [[ "$embedded" == true ]]; then
	printf '\n[video] Put processed subtitle back into media\n'

	ext=${media##*.}
	remux="$workdir/remux.$ext"
	subcodec=()

	case ${ext,,} in
		mp4|mov|m4v) subcodec=(-c:s:0 mov_text) ;;
		webm) subcodec=(-c:s:0 webvtt) ;;
	esac

	if ! ffmpeg -y -i "$media" -i "$srt" \
		-map 1:0 \
		-map 0 \
		-map -0:s:0 \
		-c copy \
		"${subcodec[@]}" \
		"$remux"; then

		printf 'Error: could not put the processed subtitle back into the media.\n' >&2
		exit 1
	fi

	mv -f -- "$remux" "$media"
	printf '\nFinished: %s\n' "${media##*/}"
else
	printf '\nFinished: %s\n' "${srt##*/}"
fi