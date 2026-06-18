#!/bin/bash

# Define required commands
# REQUIRED_COMMANDS=(stable-ts demucs ffprobe ffmpeg)
REQUIRED_COMMANDS=(whisperx ffprobe ffmpeg)

# Check if all required commands are available
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Transcribing commands are not available."
        exit 1
    fi
done

WX_GPU=(--device cpu --compute_type float32)
if python -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    WX_GPU=(--device cuda --compute_type float16)
fi

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
                whisperx --model turbo "${WX_GPU[@]}" --output_dir . --output_format srt --print_progress True "old_$file"

                srtfile="old_${filename}.srt"

                # Merge subtitle file with original video file
                if ffmpeg -i "old_$file" -i "$srtfile" -c:v copy -c:a copy -c:s copy -map 0:v -map 0:a -map 1:s -metadata:s:s:0 language=eng "${filename}.mkv"; then
                    # Remove temporary subtitle file
                    rm -rfv "$srtfile"
                fi
        fi
    fi
done