#!/bin/bash
# AI-powered file organization using Gemini Flash + liteparse
# Dedupes, classifies, renames, and organizes files in parallel

set -euo pipefail

DOWNLOADS_DIR="$HOME/Downloads"
TRASH_DIR="$HOME/.Trash"
ORGANIZE_DIR="$DOWNLOADS_DIR/.organize"
LOG_FILE="$ORGANIZE_DIR/ai-organize.log"
HASH_FILE="$ORGANIZE_DIR/.hashes"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models"

FOLDERS="Invoices Images Documents Data Code Media Resumes Misc"
INVOICE_NAME_RE='^[a-z]+(-[a-z]+)*-[0-9]{2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-[0-9]{2}$'

# Source API key from .env if not in environment
if [[ -z "${GEMINI_API_KEY:-}" ]] && [[ -f "$ORGANIZE_DIR/.env" ]]; then
    source "$ORGANIZE_DIR/.env"
fi
export GEMINI_API_KEY

MAX_PDF_INLINE=$((10 * 1024 * 1024))  # 10MB cap for inline PDF vision
LOCKFILE="$ORGANIZE_DIR/.lock"

# Prevent concurrent runs (Folder Actions can fire multiple times)
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCKFILE" 2>/dev/null' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

rotate_log() {
    local max_size=$((1 * 1024 * 1024))
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f '%z' "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $size -gt $max_size ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "Log rotated (was $(($size / 1024))KB)"
        fi
    fi
}

to_kebab_case() {
    echo "$1" | \
        sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g' | \
        sed 's/[^a-zA-Z0-9 ]/ /g' | \
        sed 's/  */ /g' | \
        sed 's/^ *//' | \
        sed 's/ *$//' | \
        sed 's/ /-/g' | \
        tr '[:upper:]' '[:lower:]' | \
        cut -c1-80
}

get_extension() {
    echo "${1##*.}" | tr '[:upper:]' '[:lower:]'
}

get_basename_no_ext() {
    local filename="$1"
    local ext="${filename##*.}"
    if [[ "$filename" == "$ext" ]]; then
        echo "$filename"
    else
        echo "${filename%.*}"
    fi
}

get_unique_path() {
    local dir="$1"
    local basename="$2"
    local ext="$3"

    local target="$dir/$basename.$ext"
    [[ ! -e "$target" ]] && echo "$target" && return

    local counter=2
    while [[ -e "$dir/$basename-$counter.$ext" ]]; do
        ((counter++))
    done
    echo "$dir/$basename-$counter.$ext"
}

# Fast extension-based fallback when Gemini is unavailable
extension_categorize() {
    local ext="$1"
    case "$ext" in
        png|jpg|jpeg|webp|gif|svg|heic) echo "Images" ;;
        mp4|mov|mp3|wav|m4a|mkv|avi) echo "Media" ;;
        csv|xlsx|xls) echo "Data" ;;
        zip|lic|vsix|exe|dmg|pkg|tar|gz) echo "Code" ;;
        pdf|docx|doc|pptx|ppt|txt|md|rtf) echo "Documents" ;;
        json) echo "Data" ;;
        *) echo "Misc" ;;
    esac
}

create_folders() {
    for folder in $FOLDERS; do
        mkdir -p "$DOWNLOADS_DIR/$folder"
    done
}

deduplicate_files() {
    local files_trashed=0
    > "$HASH_FILE"

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        local filename
        filename=$(basename "$file")
        [[ "$filename" == .* ]] && continue
        [[ "$filename" == *.crdownload ]] && continue
        [[ "$filename" == *.part ]] && continue
        [[ "$filename" == *.download ]] && continue

        local hash
        hash=$(md5 -q "$file" 2>/dev/null) || continue
        local mtime
        mtime=$(stat -f '%m' "$file")
        echo "$hash|$mtime|$file" >> "$HASH_FILE"
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    local prev_hash=""
    while IFS='|' read -r hash mtime filepath; do
        if [[ "$hash" == "$prev_hash" ]] && [[ -n "$prev_hash" ]]; then
            if [[ -f "$filepath" ]]; then
                mv "$filepath" "$TRASH_DIR/" 2>/dev/null && {
                    log "  Trashed dupe: $(basename "$filepath")"
                    ((files_trashed++)) || true
                }
            fi
        else
            prev_hash="$hash"
        fi
    done < <(sort -t'|' -k1,1 -k2,2rn "$HASH_FILE")

    rm -f "$HASH_FILE"
    echo "$files_trashed"
}

# ---------------------------------------------------------------------------
# Content extraction
# ---------------------------------------------------------------------------

extract_content() {
    local filepath="$1"
    local ext="$2"

    case "$ext" in
        pdf)
            if command -v lit &>/dev/null; then
                lit parse "$filepath" --target-pages "1-2" -q 2>/dev/null | head -150
            fi
            ;;
        docx|doc|rtf|pptx|ppt)
            local text=""
            if command -v lit &>/dev/null; then
                text=$(lit parse "$filepath" --target-pages "1-2" --no-ocr -q 2>/dev/null | head -100)
            fi
            if [[ -z "$text" ]] && command -v textutil &>/dev/null; then
                text=$(textutil -convert txt -stdout "$filepath" 2>/dev/null | head -100)
            fi
            echo "$text"
            ;;
        txt|md|csv|json)
            head -100 "$filepath" 2>/dev/null
            ;;
        xlsx|xls)
            if command -v lit &>/dev/null; then
                lit parse "$filepath" --target-pages "1" --no-ocr -q 2>/dev/null | head -100
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Gemini API
# ---------------------------------------------------------------------------

CLASSIFY_PROMPT='Classify and name this file.

Categories (pick the MOST SPECIFIC match):
- Invoices: anything requesting/confirming payment — invoices, receipts, bills, statements, payment confirmations, subscription charges, tax payments. Look for: dollar amounts, "total", "amount due", "paid", "receipt", "invoice #", vendor/merchant name, transaction IDs. If it has a charge amount and a vendor, it is an Invoice even if it also looks like a document.
- Resumes: CVs, resumes, career summaries. Look for: work experience, education, skills sections, job titles.
- Data: spreadsheets, CSV, JSON data files, datasets, exports.
- Code: installers, packages, archives, license files, executables.
- Media: video, audio files.
- Images: photos, screenshots, graphics, icons, illustrations.
- Documents: contracts, reports, proposals, guides, letters, forms, presentations — anything text-heavy that is NOT an invoice or resume.
- Misc: only if nothing else fits.

Priority: Invoices > Resumes > Data > Documents (when ambiguous between these)

Naming rules:
- Invoices: vendor-dd-mon-yy (e.g., stripe-15-dec-24, aws-01-jul-25, san-diego-county-08-mar-24)
  Use the shortest recognizable vendor name (1-3 words). Issue/payment date only, not due date.
  Examples: Amazon Web Services->aws, Google Cloud->google, Digital Ocean->digitalocean, Meat District->meat-district, HR Block->hr-block
- Resumes: firstname-lastname-role-resume (role: 1-3 words)
- Other: descriptive-kebab-case, 3-6 words, capturing the document subject'

# Call Gemini with structured JSON output
# Returns JSON: {"name": "...", "category": "..."}
gemini_request() {
    local prompt="$1"
    local image_path="${2:-}"
    local mime_type="${3:-}"
    local tmp_request
    tmp_request=$(mktemp "$ORGANIZE_DIR/.gemini_req_XXXXXX")

    if [[ -n "$image_path" ]]; then
        local base64_data
        base64_data=$(base64 -i "$image_path" | tr -d '\n')

        jq -n \
            --arg prompt "$prompt" \
            --arg base64 "$base64_data" \
            --arg mime "$mime_type" \
            '{
                contents: [{parts: [
                    {text: $prompt},
                    {inline_data: {mime_type: $mime, data: $base64}}
                ]}],
                generationConfig: {
                    responseMimeType: "application/json",
                    responseSchema: {
                        type: "OBJECT",
                        properties: {
                            name: {type: "STRING"},
                            category: {type: "STRING", enum: ["Invoices","Images","Documents","Data","Code","Media","Resumes","Misc"]}
                        },
                        required: ["name", "category"]
                    }
                }
            }' > "$tmp_request"
    else
        jq -n \
            --arg prompt "$prompt" \
            '{
                contents: [{parts: [{text: $prompt}]}],
                generationConfig: {
                    responseMimeType: "application/json",
                    responseSchema: {
                        type: "OBJECT",
                        properties: {
                            name: {type: "STRING"},
                            category: {type: "STRING", enum: ["Invoices","Images","Documents","Data","Code","Media","Resumes","Misc"]}
                        },
                        required: ["name", "category"]
                    }
                }
            }' > "$tmp_request"
    fi

    local response
    response=$(curl -s --max-time 30 \
        "$GEMINI_API_URL/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$tmp_request" 2>/dev/null)

    rm -f "$tmp_request"
    echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null
}

# Classify a file: extract content, call Gemini, return {name, category}
classify_file() {
    local filepath="$1"
    local filename="$2"
    local ext="$3"

    case "$ext" in
        png|jpg|jpeg|webp|gif|heic)
            local mime_type="image/${ext}"
            [[ "$ext" == "jpg" ]] && mime_type="image/jpeg"
            [[ "$ext" == "heic" ]] && mime_type="image/heic"

            local prompt
            prompt="$CLASSIFY_PROMPT

Current filename: $filename
Describe what you see and generate an appropriate filename."

            gemini_request "$prompt" "$filepath" "$mime_type"
            ;;
        pdf)
            local file_size
            file_size=$(stat -f '%z' "$filepath" 2>/dev/null || echo 0)

            if [[ $file_size -le $MAX_PDF_INLINE ]]; then
                local prompt
                prompt="$CLASSIFY_PROMPT

Current filename: $filename"

                gemini_request "$prompt" "$filepath" "application/pdf"
            else
                local content
                content=$(extract_content "$filepath" "$ext")
                [[ -z "$content" ]] && return 1

                local prompt
                prompt="$CLASSIFY_PROMPT

Current filename: $filename

File content:
$content"

                gemini_request "$prompt"
            fi
            ;;
        docx|doc|rtf|pptx|ppt|txt|md|csv|json|xlsx|xls)
            local content
            content=$(extract_content "$filepath" "$ext")

            if [[ -z "$content" ]]; then
                return 1
            fi

            local prompt
            prompt="$CLASSIFY_PROMPT

Current filename: $filename

File content:
$content"

            gemini_request "$prompt"
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Parallel classify + move pipeline
# ---------------------------------------------------------------------------

MAX_PARALLEL="${MAX_PARALLEL:-5}"
COUNTERS_DIR="$ORGANIZE_DIR/.counters"

# Check if a filename already matches a known good format (skip AI)
# Returns category name via stdout, or empty if not recognized
already_classified() {
    local name="$1"
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    # Invoice: vendor-dd-mon-yy with optional -N dedup suffix
    if [[ "$name_lower" =~ ${INVOICE_NAME_RE%$}(-[0-9]+)?$ ]]; then
        echo "Invoices"
        return 0
    fi
    # Resume format
    if [[ "$name_lower" =~ -resume(-[0-9]+)?$ ]]; then
        echo "Resumes"
        return 0
    fi
    return 1
}

# Classify with single retry, then move immediately
classify_and_move() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local ext
    ext=$(get_extension "$filename")
    local basename_no_ext
    basename_no_ext=$(get_basename_no_ext "$filename")

    local new_name="" category=""

    # AI classification: try twice
    local attempt=0
    while [[ $attempt -lt 2 ]]; do
        local result
        result=$(classify_file "$file" "$filename" "$ext" 2>/dev/null) || true

        if [[ -n "$result" ]]; then
            new_name=$(echo "$result" | jq -r '.name // empty' 2>/dev/null)
            category=$(echo "$result" | jq -r '.category // empty' 2>/dev/null)

            case "${category:-}" in
                Invoices|Images|Documents|Data|Code|Media|Resumes|Misc) break ;;
                *) new_name=""; category="" ;;
            esac
        fi

        ((attempt++))
    done

    if [[ -z "$category" ]]; then
        log "    AI failed after $attempt attempts: $filename"
        # Filename heuristic before falling back to extension
        local name_lower
        name_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        if [[ "$name_lower" =~ invoice|receipt|payment ]]; then
            category="Invoices"
        elif [[ "$name_lower" =~ resume|cv|curriculum ]]; then
            category="Resumes"
        else
            category=$(extension_categorize "$ext")
        fi
    fi

    # Clean up AI-generated name
    if [[ -n "$new_name" ]]; then
        if [[ "$category" == "Invoices" ]]; then
            new_name=$(echo "$new_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
            if [[ ! "$new_name" =~ $INVOICE_NAME_RE ]]; then
                log "    Invalid invoice format from AI: $new_name (file: $filename)"
                new_name=""
            fi
        else
            new_name=$(to_kebab_case "$new_name" | cut -c1-60)
        fi
    fi

    if [[ -z "$new_name" ]]; then
        new_name=$(to_kebab_case "$basename_no_ext")
    fi

    # Move to target folder
    local target_dir="$DOWNLOADS_DIR/$category"
    local target_path
    target_path=$(get_unique_path "$target_dir" "$new_name" "$ext")
    local original_kebab
    original_kebab=$(to_kebab_case "$basename_no_ext")

    mv "$file" "$target_path" 2>/dev/null && {
        if [[ "$new_name" != "$original_kebab" ]]; then
            log "  $filename -> $category/$(basename "$target_path")"
            touch "$COUNTERS_DIR/renamed_$(date +%s%N)" 2>/dev/null
        else
            log "  $filename -> $category/"
        fi
        touch "$COUNTERS_DIR/moved_$(date +%s%N)" 2>/dev/null
    }
}

process_files() {
    local ai_limit="${1:-10}"
    local ai_calls=0
    local jobs_running=0

    rm -rf "$COUNTERS_DIR"
    mkdir -p "$COUNTERS_DIR"

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue

        local filename
        filename=$(basename "$file")
        [[ "$filename" == .* ]] && continue
        [[ "$filename" == *.crdownload ]] && continue
        [[ "$filename" == *.part ]] && continue
        [[ "$filename" == *.download ]] && continue

        local ext
        ext=$(get_extension "$filename")

        local basename_no_ext
        basename_no_ext=$(get_basename_no_ext "$filename")

        # Skip AI for files that already have good names
        local known_category
        known_category=$(already_classified "$basename_no_ext") || true
        if [[ -n "$known_category" ]]; then
            local target_path
            target_path=$(get_unique_path "$DOWNLOADS_DIR/$known_category" "$(to_kebab_case "$basename_no_ext")" "$ext")
            mv "$file" "$target_path" 2>/dev/null && {
                log "  $filename -> $known_category/"
                touch "$COUNTERS_DIR/moved_$(date +%s%N)" 2>/dev/null
            }
            continue
        fi

        # AI-classifiable file types: run in parallel
        case "$ext" in
            png|jpg|jpeg|webp|gif|heic|pdf|docx|doc|rtf|pptx|ppt|txt|md|csv|json|xlsx|xls)
                if [[ $ai_calls -lt $ai_limit ]]; then
                    classify_and_move "$file" &
                    ((ai_calls++)) || true
                    ((jobs_running++)) || true

                    # Stagger launches to avoid API rate limit bursts
                    sleep 0.2

                    if [[ $jobs_running -ge $MAX_PARALLEL ]]; then
                        wait -n 2>/dev/null || true
                        ((jobs_running--)) || true
                    fi
                    continue
                fi
                ;;
        esac

        # Non-classifiable files: move immediately with extension-based category
        local category
        category=$(extension_categorize "$ext")
        local new_name
        new_name=$(to_kebab_case "$basename_no_ext")
        local target_path
        target_path=$(get_unique_path "$DOWNLOADS_DIR/$category" "$new_name" "$ext")

        mv "$file" "$target_path" 2>/dev/null && {
            log "  $filename -> $category/"
            touch "$COUNTERS_DIR/moved_$(date +%s%N)" 2>/dev/null
        }
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    wait  # Wait for all background classify+move jobs

    local moved renamed
    moved=$(find "$COUNTERS_DIR" -name 'moved_*' 2>/dev/null | wc -l | tr -d ' ')
    renamed=$(find "$COUNTERS_DIR" -name 'renamed_*' 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$COUNTERS_DIR"

    echo "$moved $renamed $ai_calls"
}

# ---------------------------------------------------------------------------
# Zip extraction
# ---------------------------------------------------------------------------

extract_zips() {
    local extracted=0
    local limit="${1:-5}"
    local max_zip_size=$((100 * 1024 * 1024))

    while IFS= read -r -d '' zipfile; do
        [[ -f "$zipfile" ]] || continue
        [[ $extracted -ge $limit ]] && break

        local filename
        filename=$(basename "$zipfile")
        [[ "$filename" == .* ]] && continue
        [[ "${filename##*.}" == "zip" ]] || continue

        local zip_size
        zip_size=$(stat -f '%z' "$zipfile" 2>/dev/null || echo 0)
        if [[ $zip_size -gt $max_zip_size ]]; then
            log "  Skipping large zip ($(($zip_size / 1024 / 1024))MB): $(basename "$zipfile")"
            continue
        fi

        local zipname
        zipname=$(basename "$zipfile" .zip)
        local extract_dir="$ORGANIZE_DIR/.extract_tmp"

        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"

        if ! unzip -q -o "$zipfile" -d "$extract_dir" 2>/dev/null; then
            rm -rf "$extract_dir"
            continue
        fi

        log "  Extracting: $zipname.zip"

        local file_count=0
        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue
            local extracted_filename
            extracted_filename=$(basename "$file")
            [[ "$extracted_filename" == .* ]] && continue
            [[ "$extracted_filename" == "__MACOSX" ]] && continue

            local base ext target
            base=$(get_basename_no_ext "$extracted_filename")
            ext=$(get_extension "$extracted_filename")
            target=$(get_unique_path "$DOWNLOADS_DIR" "$base" "$ext")

            mv "$file" "$target" 2>/dev/null && ((file_count++)) || true
        done < <(find "$extract_dir" -type f -print0 2>/dev/null)

        rm -rf "$extract_dir"

        if [[ $file_count -gt 0 ]]; then
            log "    -> $file_count files extracted to Downloads"
            mv "$zipfile" "$TRASH_DIR/" 2>/dev/null || true
            ((extracted++))
        fi
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "$extracted"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local limit="${1:-10}"

    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
        log "WARNING: GEMINI_API_KEY not set — extension-based categorization only"
        log "  Set it in $ORGANIZE_DIR/.env or as an environment variable"
    fi

    rotate_log
    create_folders

    local zips_extracted
    zips_extracted=$(extract_zips 5)

    local dupes
    dupes=$(deduplicate_files)

    local result
    result=$(process_files "$limit")
    local moved renamed ai_calls
    moved=$(echo "$result" | cut -d' ' -f1)
    renamed=$(echo "$result" | cut -d' ' -f2)
    ai_calls=$(echo "$result" | cut -d' ' -f3)

    log "Done: $moved organized, $renamed renamed, $dupes dupes, $zips_extracted zips ($ai_calls AI calls)"
    echo "Done: $moved organized, $renamed renamed, $dupes dupes, $zips_extracted zips ($ai_calls AI calls)"
}

main "$@"
