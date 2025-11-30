#!/bin/bash
# AI-powered file organization using Ollama
# Dedupes, categorizes, moves, and AI-renames generic files

set -euo pipefail

DOWNLOADS_DIR="$HOME/Downloads"
TRASH_DIR="$HOME/.Trash"
LOG_FILE="$DOWNLOADS_DIR/.organize/ai-organize.log"
HASH_FILE="$DOWNLOADS_DIR/.organize/.hashes"
TEXT_MODEL="llama3.2"
VISION_MODEL="moondream"

FOLDERS="Invoices Images Documents Data Code Media Resumes Misc"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Rotate log if over 1MB
rotate_log() {
    local max_size=$((1 * 1024 * 1024))  # 1MB
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

# AI categorization - returns folder name
ai_categorize() {
    local filename="$1"
    local ext="$2"

    local prompt="Categorize this file into exactly ONE of these folders: Invoices, Images, Documents, Data, Code, Media, Resumes, Misc

Filename: $filename
Extension: $ext

Rules:
- Invoices: billing, receipt, invoice, statement, subscription documents (PDF only)
- Images: photos, screenshots, graphics, icons, artwork
- Documents: reports, papers, presentations, text files, PDFs (non-invoice)
- Data: spreadsheets, CSV, JSON, databases
- Code: source code, archives, installers, packages, configs
- Media: video, audio files
- Resumes: CV, resume documents
- Misc: anything else

Reply with ONLY the folder name, nothing else."

    local result
    result=$(echo "$prompt" | ollama run "$TEXT_MODEL" 2>/dev/null | head -1 | tr -d '[:space:]')

    # Validate result is a valid folder
    case "$result" in
        Invoices|Images|Documents|Data|Code|Media|Resumes|Misc)
            echo "$result"
            ;;
        *)
            # Fallback to extension-based
            echo ""
            ;;
    esac
}

# Fast extension-based fallback
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

extract_date_from_name() {
    local name="$1"
    local match
    match=$(echo "$name" | /usr/bin/grep -oE '[0-9]{4}[-_][0-9]{2}[-_][0-9]{2}' | head -1)
    if [[ -n "$match" ]]; then
        local year="${match:0:4}"
        local month_num="${match:5:2}"
        local short_year="${year:2:2}"
        local month_name
        case "$month_num" in
            01) month_name="jan" ;; 02) month_name="feb" ;; 03) month_name="mar" ;;
            04) month_name="apr" ;; 05) month_name="may" ;; 06) month_name="jun" ;;
            07) month_name="jul" ;; 08) month_name="aug" ;; 09) month_name="sep" ;;
            10) month_name="oct" ;; 11) month_name="nov" ;; 12) month_name="dec" ;;
        esac
        echo "$month_name-$short_year"
        return
    fi

    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    local month_match year_match
    month_match=$(echo "$name_lower" | /usr/bin/grep -oE '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)' | head -1)
    year_match=$(echo "$name" | /usr/bin/grep -oE '20[0-9]{2}' | head -1)

    if [[ -n "$month_match" ]] && [[ -n "$year_match" ]]; then
        local short_year="${year_match:2:2}"
        echo "$month_match-$short_year"
        return
    fi
    echo ""
}

strip_date_from_name() {
    echo "$1" | \
        sed -E 's/^[0-9]{4}-[0-9]{2}-//g' | \
        sed -E 's/-[0-9]{4}-[0-9]{2}$//g' | \
        sed -E 's/[0-9]{4}[-_][0-9]{2}[-_][0-9]{2}//g' | \
        sed -E 's/(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)[-_ ]*[0-9]{0,2}[-_, ]*20[0-9]{2}//gi' | \
        sed -E 's/20[0-9]{2}[-_ ]*(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)[-_ ]*[0-9]{0,2}//gi' | \
        sed -E 's/(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)[-_ ]+20[0-9]{2}//gi' | \
        sed -E 's/20[0-9]{2}//g' | \
        sed -E 's/[[:space:]]+/ /g' | \
        sed -E 's/[-_ ]+$//g' | \
        sed -E 's/^[-_ ]+//g' | \
        sed 's/^ *//' | sed 's/ *$//'
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

organize_files() {
    local files_moved=0
    local use_ai="${1:-true}"

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

        # Try AI categorization first if enabled
        local category=""
        if [[ "$use_ai" == "true" ]]; then
            category=$(ai_categorize "$filename" "$ext")
        fi

        # Fallback to extension-based
        if [[ -z "$category" ]]; then
            category=$(extension_categorize "$ext")
        fi

        # Special overrides for keywords
        local name_lower
        name_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        if echo "$name_lower" | /usr/bin/grep -qiE '(resume|cv)'; then
            category="Resumes"
        elif [[ "$ext" == "pdf" ]] && echo "$name_lower" | /usr/bin/grep -qiE '(invoice|receipt|statement|billing|subscription)'; then
            category="Invoices"
        fi

        local new_basename
        new_basename=$(to_kebab_case "$basename_no_ext")

        # Invoice date suffix
        if [[ "$category" == "Invoices" ]]; then
            local date_suffix
            date_suffix=$(extract_date_from_name "$filename")
            local clean_basename
            clean_basename=$(strip_date_from_name "$basename_no_ext")
            new_basename=$(to_kebab_case "$clean_basename")
            if [[ -z "$date_suffix" ]]; then
                date_suffix=$(stat -f '%Sm' -t '%b-%y' "$file" | tr '[:upper:]' '[:lower:]')
            fi
            new_basename="$new_basename-$date_suffix"
        fi

        local target_dir="$DOWNLOADS_DIR/$category"
        local target_path
        target_path=$(get_unique_path "$target_dir" "$new_basename" "$ext")

        mv "$file" "$target_path" 2>/dev/null && {
            log "  $filename -> $category/$(basename "$target_path")"
            ((files_moved++)) || true
        }
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "$files_moved"
}

# Dedupe files across all organized folders
deduplicate_all_folders() {
    local files_trashed=0
    > "$HASH_FILE"

    for folder in $FOLDERS; do
        local folder_path="$DOWNLOADS_DIR/$folder"
        [[ -d "$folder_path" ]] || continue

        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue
            local filename
            filename=$(basename "$file")
            [[ "$filename" == .* ]] && continue

            local hash
            hash=$(md5 -q "$file" 2>/dev/null) || continue
            local mtime
            mtime=$(stat -f '%m' "$file")
            echo "$hash|$mtime|$file" >> "$HASH_FILE"
        done < <(find "$folder_path" -maxdepth 1 -type f -print0 2>/dev/null)
    done

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

# Check if filename is generic (for AI renaming)
is_generic_name() {
    local name="$1"
    echo "$name" | /usr/bin/grep -qiE '^(image|img|screenshot|photo|picture|pako|dsc|dcim)' && return 0
    echo "$name" | /usr/bin/grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}' && return 0
    echo "$name" | /usr/bin/grep -qiE '^gen[-_ ]' && return 0
    echo "$name" | /usr/bin/grep -qiE '^(receipt|invoice|payment|billing|statement|document|file|scan)[-_][0-9]' && return 0
    echo "$name" | /usr/bin/grep -qiE '^(download|untitled|new|temp)' && return 0
    return 1
}

# AI rename image using vision model
ai_rename_image() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local ext="${filename##*.}"
    local basename_no_ext="${filename%.*}"

    if ! is_generic_name "$basename_no_ext"; then
        return 1
    fi

    log "  AI renaming image: $filename"

    local description
    description=$(ollama run "$VISION_MODEL" "What is in this image? Describe it in 3-5 words suitable for a filename." "$filepath" 2>/dev/null | tr -cd '[:print:]\n' | /usr/bin/grep -v "Added image" | /usr/bin/grep -v "^\[" | /usr/bin/grep -v "^$" | head -1 | tr -d '\n')

    if [[ -z "$description" ]]; then
        return 1
    fi

    local new_name
    new_name=$(to_kebab_case "$description" | cut -c1-50)

    if [[ -z "$new_name" ]]; then
        return 1
    fi

    local target
    target=$(get_unique_path "$(dirname "$filepath")" "$new_name" "$ext")
    mv "$filepath" "$target" && {
        log "    -> $(basename "$target")"
        return 0
    }
    return 1
}

# AI rename PDF using text extraction
ai_rename_pdf() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local basename_no_ext="${filename%.pdf}"

    if ! is_generic_name "$basename_no_ext"; then
        return 1
    fi

    # Need pdftotext
    if ! command -v pdftotext &>/dev/null; then
        return 1
    fi

    log "  AI renaming PDF: $filename"

    local text
    text=$(pdftotext -l 1 "$filepath" - 2>/dev/null | head -60)

    if [[ -z "$text" ]]; then
        return 1
    fi

    local prompt="Based on this document text, generate a short descriptive filename (3-6 words). Include the company/source name if identifiable. Reply with ONLY the filename words, nothing else.

Text:
$text"

    local new_name
    new_name=$(echo "$prompt" | ollama run "$TEXT_MODEL" 2>/dev/null | head -1 | tr -d '\n')
    new_name=$(echo "$new_name" | sed 's/^[^a-zA-Z]*//' | sed 's/[^a-zA-Z0-9 -]*$//' | sed 's/\.pdf$//')

    if [[ -z "$new_name" ]]; then
        return 1
    fi

    local name_kebab
    name_kebab=$(to_kebab_case "$new_name" | cut -c1-60)

    # Add date for invoices/receipts
    if echo "$new_name" | /usr/bin/grep -qiE '(invoice|receipt|statement|billing)'; then
        local date_suffix
        date_suffix=$(extract_date_from_name "$filename")
        if [[ -z "$date_suffix" ]]; then
            date_suffix=$(stat -f '%Sm' -t '%b-%y' "$filepath" | tr '[:upper:]' '[:lower:]')
        fi
        name_kebab="${name_kebab}-${date_suffix}"
    fi

    local target
    target=$(get_unique_path "$(dirname "$filepath")" "$name_kebab" "pdf")
    mv "$filepath" "$target" && {
        log "    -> $(basename "$target")"
        return 0
    }
    return 1
}

# AI rename files in Downloads root (before organizing)
ai_rename_files() {
    local renamed=0
    local limit="${1:-10}"

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        [[ $renamed -ge $limit ]] && break

        local filename
        filename=$(basename "$file")
        [[ "$filename" == .* ]] && continue
        [[ "$filename" == *.crdownload ]] && continue
        [[ "$filename" == *.part ]] && continue
        [[ "$filename" == *.download ]] && continue

        local ext="${file##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

        # Try images first
        case "$ext" in
            png|jpg|jpeg|webp|gif|heic)
                if ai_rename_image "$file"; then
                    ((renamed++))
                fi
                ;;
            pdf)
                if ai_rename_pdf "$file"; then
                    ((renamed++))
                fi
                ;;
        esac
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "$renamed"
}

# Extract and organize zip contents
extract_and_organize_zips() {
    local extracted=0
    local limit="${1:-5}"
    local max_zip_size=$((100 * 1024 * 1024))  # 100MB max

    for zipfile in "$DOWNLOADS_DIR/Code"/*.zip; do
        [[ -f "$zipfile" ]] || continue
        [[ $extracted -ge $limit ]] && break

        # Skip large zips
        local zip_size
        zip_size=$(stat -f '%z' "$zipfile" 2>/dev/null || echo 0)
        if [[ $zip_size -gt $max_zip_size ]]; then
            log "  Skipping large zip ($(($zip_size / 1024 / 1024))MB): $(basename "$zipfile")"
            continue
        fi

        local zipname
        zipname=$(basename "$zipfile" .zip)
        local extract_dir="$DOWNLOADS_DIR/.organize/.extract_tmp"

        # Create temp extraction dir
        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"

        # Extract
        if ! unzip -q -o "$zipfile" -d "$extract_dir" 2>/dev/null; then
            rm -rf "$extract_dir"
            continue
        fi

        log "  Extracting: $zipname.zip"

        # Move extracted files to appropriate folders
        local file_count=0
        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue
            local filename
            filename=$(basename "$file")
            [[ "$filename" == .* ]] && continue
            [[ "$filename" == "__MACOSX" ]] && continue

            local ext
            ext=$(get_extension "$filename")
            local category
            category=$(extension_categorize "$ext")

            local new_basename
            new_basename=$(to_kebab_case "$(get_basename_no_ext "$filename")")
            local target_path
            target_path=$(get_unique_path "$DOWNLOADS_DIR/$category" "$new_basename" "$ext")

            mv "$file" "$target_path" 2>/dev/null && ((file_count++)) || true
        done < <(find "$extract_dir" -type f -print0 2>/dev/null)

        # Cleanup
        rm -rf "$extract_dir"

        if [[ $file_count -gt 0 ]]; then
            log "    -> $file_count files extracted and organized"
            # Trash the original zip after successful extraction
            mv "$zipfile" "$TRASH_DIR/" 2>/dev/null || true
            ((extracted++))
        fi
    done

    echo "$extracted"
}

main() {
    local use_ai="${1:-true}"
    local rename_limit="${2:-10}"

    # Check models
    local has_text_model has_vision_model
    has_text_model=$(ollama list 2>/dev/null | /usr/bin/grep "$TEXT_MODEL" || true)
    has_vision_model=$(ollama list 2>/dev/null | /usr/bin/grep "$VISION_MODEL" || true)

    if [[ -z "$has_text_model" ]]; then
        use_ai="false"
    fi

    rotate_log
    create_folders

    # Step 1: Dedupe
    local dupes=0
    dupes=$(deduplicate_files)

    # Step 2: AI rename generic files BEFORE organizing (if models available)
    local renamed=0
    if [[ "$use_ai" == "true" ]] && [[ -n "$has_text_model" || -n "$has_vision_model" ]]; then
        renamed=$(ai_rename_files "$rename_limit")
    fi

    # Step 3: Organize/move files (with AI-renamed names)
    local moved
    moved=$(organize_files "$use_ai")

    # Step 4: Extract zips and organize contents
    local zips_extracted
    zips_extracted=$(extract_and_organize_zips 5)

    # Step 5: Dedupe again after zip extraction
    local dupes2=0
    dupes2=$(deduplicate_all_folders)
    dupes=$((dupes + dupes2))

    log "Done: $moved organized, $dupes dupes, $zips_extracted zips, $renamed renamed"
    echo "Done: $moved organized, $dupes dupes, $zips_extracted zips, $renamed AI-renamed"
}

main "$@"
