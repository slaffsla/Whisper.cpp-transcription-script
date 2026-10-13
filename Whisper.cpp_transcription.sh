#!/bin/bash

# ---------- Configuration ----------
SOURCE_ROOT="/Volumes/home/Whisper batch tmp"
OUTPUT_ROOT="$SOURCE_ROOT/Whisper_Transcripts"

MODEL="$HOME/whisper-models/ggml-large-v3.bin"
WHISPER="$HOME/whisper.cpp/build/bin/whisper-cli"

THREADS=6
TRANSLATE_EN=0

# Maximum number of new files attempted per run.
# Set to 0 to process all remaining files.
BATCH_SIZE=5

# ---------- Validate paths ----------
if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "ERROR: Source folder not found:"
    echo "$SOURCE_ROOT"
    exit 1
fi

if [[ ! -f "$MODEL" ]]; then
    echo "ERROR: Model not found: $MODEL"
    exit 1
fi

if [[ ! -x "$WHISPER" ]]; then
    echo "ERROR: whisper-cli not found: $WHISPER"
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg is not installed or not in PATH."
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"

echo "Source:      $SOURCE_ROOT"
echo "Output:      $OUTPUT_ROOT"
echo "Model:       $MODEL"
echo "Threads:     $THREADS"
echo "Translation: $TRANSLATE_EN"
echo "Batch size:  $BATCH_SIZE"
echo

processed=0
skipped=0
failed=0
attempted=0

while IFS= read -r -d '' file; do

    # Stop after the configured number of new files attempted.
    if [[ "$BATCH_SIZE" -gt 0 && "$attempted" -ge "$BATCH_SIZE" ]]; then
        break
    fi

    # Preserve the source folder structure.
    relative="${file#"$SOURCE_ROOT"/}"
    relative_no_ext="${relative%.*}"
    prefix="$OUTPUT_ROOT/$relative_no_ext"

    mkdir -p "$(dirname "$prefix")"

    # Skip files already transcribed, including translation if enabled.
    if [[ -s "$prefix.txt" && -s "$prefix.srt" ]]; then
        if [[ "$TRANSLATE_EN" -eq 0 || -s "$prefix.en.txt" ]]; then
            echo "SKIP: $relative"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    attempted=$((attempted + 1))

    echo
    echo "[$attempted/$BATCH_SIZE] PROCESSING: $relative"

    # Temporary audio is stored on the Mac, not beside the NAS source.
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/whisper.XXXXXX")" || {
        echo "ERROR: Could not create temporary directory."
        failed=$((failed + 1))
        continue
    }

    wav="$tmpdir/audio.wav"

    if ! ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$file" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$wav"; then
        echo "ERROR: Audio extraction failed: $relative"
        rm -rf "$tmpdir"
        failed=$((failed + 1))
        continue
    fi

    # Russian transcription and timestamped subtitles.
    if ! "$WHISPER" \
        -m "$MODEL" \
        -f "$wav" \
        -l ru \
        -t "$THREADS" \
        -bs 5 \
        -bo 5 \
        -otxt \
        -osrt \
        -of "$prefix"; then

        echo "ERROR: Russian transcription failed: $relative"
        rm -rf "$tmpdir"
        failed=$((failed + 1))
        continue
    fi

    # Optional separate English translation.
    if [[ "$TRANSLATE_EN" -eq 1 ]]; then
        echo "English translation: $relative"

        if ! "$WHISPER" \
            -m "$MODEL" \
            -f "$wav" \
            -l ru \
            -tr \
            -t "$THREADS" \
            -bs 5 \
            -bo 5 \
            -otxt \
            -of "$prefix.en"; then

            echo "WARNING: English translation failed: $relative"
            failed=$((failed + 1))
            rm -rf "$tmpdir"
            continue
        fi
    fi

    echo "DONE: $relative"
    processed=$((processed + 1))

    rm -rf "$tmpdir"

done < <(
    find "$SOURCE_ROOT" \
        -path "$OUTPUT_ROOT" -prune -o \
        -type f \( \
            -iname '*.mov' -o -iname '*.mp4' -o \
            -iname '*.m4v' -o -iname '*.mkv' -o \
            -iname '*.avi' -o -iname '*.webm' -o \
            -iname '*.mp3' -o -iname '*.m4a' -o \
            -iname '*.wav' -o -iname '*.aac' -o \
            -iname '*.flac' -o -iname '*.ogg' -o \
            -iname '*.opus' -o -iname '*.wma' -o \
            -iname '*.aiff' -o -iname '*.caf' \
        \) -print0
)

echo
echo "========== BATCH SUMMARY =========="
echo "New files completed: $processed"
echo "Already completed:   $skipped"
echo "Failed:              $failed"
echo "Output folder:       $OUTPUT_ROOT"
echo "Run again to continue with remaining files."
