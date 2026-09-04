#!/usr/bin/env bash

# Synchronize supplied SRTs, clean/reflow the first (English) subtitle,
# then perform a conservative final synchronization and lint.
set -u

usage() {
	printf 'Usage: %s [--skip-sync] MEDIA ENGLISH_SRT [SOURCE_SRT ...]\n' "${0##*/}" >&2
}

skip_sync=false
if [[ "${1:-}" == --skip-sync ]]; then
	skip_sync=true
	shift
fi

if (($# < 2)); then
	usage
	exit 2
fi

media=$1
srt=$2

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
		printf '\n[1/4] Initial subtitle synchronization\n'
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
	printf '\n[1/4] Synchronization skipped by --skip-sync\n'
fi


# ---------------------------------------------------------------------------
# 2. English subtitle cleanup and sentence-aware line-break placement
#
# The custom XML comes after `--balance-lines` because it is allowed to
# override a merely geometric/balanced newline when an existing sentence
# boundary gives a more natural reading break.
# ---------------------------------------------------------------------------

printf '\n[2/4] Clean and reflow English subtitles\n'

if ! command -v seconv >/dev/null 2>&1; then
	printf 'Error: seconv is required for the cleanup stage.\n' >&2
	exit 1
fi

main="$workdir/main.srt"
sentence_aware="$workdir/sentence-aware.srt"
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
        <FindWhat>^(.+)\n([^.!?…]*[.!?…]["'”’)]?)\s+(.+)$</FindWhat>
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
# 3. Timing cleanup
# ---------------------------------------------------------------------------
if ! seconv "$sentence_aware" subrip \
	--fix-common-errors-rules:FixOverlappingDisplayTimes \
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
# 4. Conservative final ffsubsync pass
#
# `--max-offset-seconds 2` means the second pass may only look for a small global correction.
#
# If the command fails, backup pre-final-sync SRT is restored.
# ---------------------------------------------------------------------------

if [[ "$skip_sync" == false ]]; then
	printf '\n[3/4] Conservative final synchronization\n'

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
	printf '\n[3/4] Final synchronization skipped by --skip-sync\n'
fi


# ---------------------------------------------------------------------------
# Final lint
# ---------------------------------------------------------------------------

printf '\n[4/4] Validate final subtitle\n'

if seconv lint "$srt"; then
	printf 'Lint: no reported problems.\n'
else
	printf 'Lint found items in the final subtitle.\n' >&2
fi

printf '\nFinished: %s\n' "${srt##*/}"