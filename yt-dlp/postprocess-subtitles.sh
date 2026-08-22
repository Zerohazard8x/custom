#!/usr/bin/env bash

# Synchronize supplied SRTs and clean the first (English) one in place. Each
# tool is optional, which lets this script use what is available on the system.
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
shift

if [[ ! -f "$media" ]]; then
	printf 'Error: media file not found: %s\n' "$media" >&2
	exit 1
fi
# With MEDIA shifted away, `for s; do` covers every subtitle argument without
# copying the list; `$srt` still names the first one for English-only cleanup.
for s; do
	if [[ ! -f "$s" ]]; then
		printf 'Error: subtitle file not found: %s\n' "$s" >&2
		exit 1
	fi
done

workdir=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-postprocess.XXXXXX") || exit 1
trap 'rm -rf -- "$workdir"' EXIT

if [[ "$skip_sync" == false ]]; then
	if command -v ffsubsync >/dev/null 2>&1; then
		printf '\n[1/2] Synchronize subtitle timings\n'
		# One ffsubsync call shares its reference-audio extraction across every input;
		# `--overwrite-input` is required by ffsubsync when `-i` names multiple SRTs.
		if ! ffsubsync "$media" -i "$@" --overwrite-input \
			--skip-sync-on-low-quality --no-fix-framerate; then
			printf 'ffsubsync failed; retaining the last valid timings.\n' >&2
		fi
	else
		printf 'ffsubsync not found; retaining the current timings.\n'
	fi
else
	printf 'Synchronization skipped because the subtitles are already aligned.\n'
fi

# Keep seconv on the first/English SRT because this recipe contains
# spacing-sensitive fixes and replacement rules that can alter other languages.
if command -v seconv >/dev/null 2>&1; then
	printf '\n[2/2] Clean and reflow English subtitles\n'
	rules="$workdir/sentence-line-breaks.xml"
	cat >"$rules" <<'EOF2'
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
EOF2

	main="$workdir/main.srt"
	final="$workdir/final.srt"
	if seconv "$srt" subrip \
		--merge-short-lines \
		--split-long-lines \
		--balance-lines \
		--fix-common-errors-rules:"Fix3PlusLines,FixEmptyLines,FixInvalidItalicTags,FixMissingSpaces,FixUnneededSpaces,NormalizeStrings,FixShortLines" \
		--apply-duration-limits \
		--output-folder:"$workdir" \
		--output-filename:"${main##*/}" \
		--overwrite &&
		seconv "$main" subrip \
			--fix-common-errors-rules:FixOverlappingDisplayTimes \
			--multiple-replace:"$rules" \
			--apply-min-gap:24 \
			--output-folder:"$workdir" \
			--output-filename:"${final##*/}" \
			--overwrite; then
		mv -f -- "$final" "$srt"
		printf '\n[lint] Validate final subtitle\n'
		if seconv lint "$srt"; then
			printf 'Lint: no reported problems.\n'
		else
			printf 'Lint found items.\n' >&2
		fi
	else
		printf 'seconv processing failed; retaining the last valid subtitles.\n' >&2
		exit 1
	fi
else
	printf 'seconv not found; skipping subtitle cleanup.\n'
fi

printf '\nFinished: %s\n' "${srt##*/}"
