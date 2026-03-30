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

# Standard filename formats:
# - Resumes: firstname-lastname-role-resume.ext
# - Invoices: company-service-mon-yy.ext
# - Images: descriptive-name.ext
# - Documents: descriptive-name.ext

# Check if filename matches expected format (returns 0 if needs fixing, 1 if OK)
needs_format_fix() {
    local name="$1"
    local category="$2"

    if ! command -v ollama &>/dev/null; then
        return 1  # No AI, can't check
    fi

    local format_spec=""
    case "$category" in
        resume)
            format_spec="firstname-lastname-role-resume"
            ;;
        invoice)
            format_spec="company-service-mon-yy (e.g., aws-hosting-jan-25)"
            ;;
        image)
            format_spec="descriptive-kebab-case (e.g., sunset-beach-photo)"
            ;;
        document)
            format_spec="descriptive-kebab-case (e.g., project-proposal)"
            ;;
        *)
            return 1  # Unknown category
            ;;
    esac

    local prompt="Check if filename '$name' matches format: $format_spec

Reply ONLY with JSON: {\"matches\": true/false, \"reason\": \"explanation\"}

Rules for resume format (firstname-lastname-role-resume):
- MUST end with \"-resume\" (literally)
- MUST be EXACTLY 4 hyphen-separated parts: firstname-lastname-role-resume
- Role should be 1-3 words describing the position (e.g., frontend-developer, senior-engineer, product-manager)
- \"cv\" is NOT a first name - files starting with \"cv-\" are WRONG
- NO dates/numbers like \"12-9-25\", \"copy\", \"v2\"
- NO extra words like \"documentation\", \"business\" after role
- CORRECT: john-smith-frontend-developer-resume, jane-doe-product-manager-resume, marcus-hugh-senior-frontend-developer-resume
- WRONG: cv-marcus-hugh, john-smith-resume (missing role), john-smith-senior-resume-copy, mezdef-documentation-resume

Rules for invoice format (company-service-mon-yy):
- MUST have date at end: mon-yy (e.g. jan-25)
- Format: company + service + date
- Examples: aws-hosting-jan-25 ✓, stripe-api-dec-24 ✓
- BAD: invoice-aws-jan-25 ✗, aws-january-2025 ✗"

    local full_output
    full_output=$(echo "$prompt" | ollama run "$TEXT_MODEL" 2>/dev/null)

    # Extract matches value directly from output (avoid complex JSON parsing)
    local matches
    matches=$(echo "$full_output" | tail -3 | /usr/bin/grep -oE '"matches":\s*(true|false)' | tail -1 | /usr/bin/grep -oE '(true|false)')

    if [[ -z "$matches" ]]; then
        return 1  # Can't parse, skip
    fi

    if [[ "$matches" == "false" ]]; then
        return 0  # Needs fix
    fi
    return 1  # Already good format
}

# AI rename image using vision model
ai_rename_image() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local ext="${filename##*.}"
    local basename_no_ext="${filename%.*}"

    if ! needs_format_fix "$basename_no_ext" "image"; then
        return 1  # Already good format
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

    # Need liteparse (lit) for PDF text extraction
    if ! command -v lit &>/dev/null; then
        log "    liteparse not installed (brew install llamaindex-liteparse)"
        return 1
    fi

    local text
    text=$(lit parse "$filepath" --target-pages "1-2" -q 2>/dev/null | head -150)

    if [[ -z "$text" ]]; then
        log "    No text extracted from: $filename"
        return 1
    fi

    # Determine document type from content
    local is_invoice=false
    local is_resume=false
    if echo "$text" | /usr/bin/grep -qiE '(invoice|receipt|statement|billing|amount due|payment)'; then
        is_invoice=true
    elif echo "$text" | /usr/bin/grep -qiE '(resume|curriculum vitae|professional experience|work experience|education|skills|objective)'; then
        is_resume=true
    fi

    local category="document"
    [[ "$is_invoice" == "true" ]] && category="invoice"
    [[ "$is_resume" == "true" ]] && category="resume"

    if ! needs_format_fix "$basename_no_ext" "$category"; then
        return 1  # Already good format
    fi

    log "  AI renaming PDF: $filename"

    local prompt
    if [[ "$is_resume" == "true" ]]; then
        prompt="Extract from this resume: person's name and their role/title. Format as: firstname-lastname-role-resume

Text:
$text

Role should be 1-3 words (e.g., frontend-developer, senior-engineer, product-manager, data-scientist)
Reply with ONLY the formatted name (e.g., john-doe-frontend-developer-resume), nothing else."
    elif [[ "$is_invoice" == "true" ]]; then
        prompt="From this invoice, extract:
1. VENDOR: Short canonical company name (not full legal name)
2. DATE: The invoice ISSUE date (labeled 'Date of issue', 'Invoice date', or 'Date'). NOT the billing period, NOT the due date.

Common vendor mappings:
- Amazon Web Services, AWS Inc → aws
- Stripe, Inc → stripe
- Google Cloud, Google LLC → google
- Intercom, Inc → intercom
- Digital Ocean → digitalocean
- Heroku → heroku
- Vercel Inc → vercel
- Netlify → netlify
- GitHub → github
- Cloudflare → cloudflare
- Apple Inc → apple
- Microsoft → microsoft

Format: vendor-mon-yy (3-letter month, 2-digit year)
- mon = jan/feb/mar/apr/may/jun/jul/aug/sep/oct/nov/dec
- yy = last 2 digits of year (2024 → 24, 2025 → 25)

Examples: aws-jul-25, stripe-dec-24, intercom-nov-24

Text:
$text

Reply with ONLY the filename (e.g., intercom-jul-25), nothing else."
    else
        prompt="Based on this document, generate a descriptive filename (3-6 words). Include company/source if identifiable.

Text:
$text

Reply with ONLY the filename words, nothing else."
    fi

    local new_name
    new_name=$(echo "$prompt" | ollama run "$TEXT_MODEL" 2>/dev/null | head -1 | tr -d '\n')
    new_name=$(echo "$new_name" | sed 's/^[^a-zA-Z]*//' | sed 's/[^a-zA-Z0-9 -]*$//' | sed 's/\.pdf$//')

    if [[ -z "$new_name" ]]; then
        return 1
    fi

    local name_kebab
    if [[ "$is_invoice" == "true" ]]; then
        # Invoice: AI returns vendor-mon-yy format directly, just clean and validate
        name_kebab=$(echo "$new_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
        # Validate invoice format: word-mon-yy (e.g., intercom-jul-25)
        if [[ ! "$name_kebab" =~ ^[a-z]+-[a-z]{3}-[0-9]{2}$ ]]; then
            log "    Invalid invoice format from AI: $name_kebab"
            return 1
        fi
    else
        name_kebab=$(to_kebab_case "$new_name" | cut -c1-60)
    fi

    local target
    target=$(get_unique_path "$(dirname "$filepath")" "$name_kebab" "pdf")
    mv "$filepath" "$target" && {
        log "    -> $(basename "$target")"
        return 0
    }
    return 1
}

# AI rename text documents (docx, doc, txt, rtf)
ai_rename_document() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local ext="${filename##*.}"
    local basename_no_ext="${filename%.*}"

    local text=""
    case "$ext" in
        docx|doc|rtf)
            # Use liteparse for office docs (supports docx, doc, rtf via LibreOffice)
            if command -v lit &>/dev/null; then
                text=$(lit parse "$filepath" --target-pages "1-2" --no-ocr -q 2>/dev/null | head -100)
            fi
            # Fallback to textutil on macOS
            if [[ -z "$text" ]] && command -v textutil &>/dev/null; then
                text=$(textutil -convert txt -stdout "$filepath" 2>/dev/null | head -100)
            fi
            ;;
        txt|md)
            text=$(head -100 "$filepath" 2>/dev/null)
            ;;
    esac

    if [[ -z "$text" ]]; then
        return 1
    fi

    # Determine if it's a resume
    local is_resume=false
    if echo "$text" | /usr/bin/grep -qiE '(resume|curriculum vitae|professional experience|work experience|education|skills|objective)'; then
        is_resume=true
    fi

    local category="document"
    [[ "$is_resume" == "true" ]] && category="resume"

    if ! needs_format_fix "$basename_no_ext" "$category"; then
        return 1  # Already good format
    fi

    log "  AI renaming document: $filename"

    local prompt
    if [[ "$is_resume" == "true" ]]; then
        prompt="Extract from this resume: person's name and their role/title. Format as: firstname-lastname-role-resume

Text:
$text

Role should be 1-3 words (e.g., frontend-developer, senior-engineer, product-manager, data-scientist)
Reply with ONLY the formatted name (e.g., john-doe-frontend-developer-resume), nothing else."
    else
        prompt="Based on this document, generate a descriptive filename (3-6 words). Include company/source if identifiable.

Text:
$text

Reply with ONLY the filename words, nothing else."
    fi

    local new_name
    new_name=$(echo "$prompt" | ollama run "$TEXT_MODEL" 2>/dev/null | head -1 | tr -d '\n')
    new_name=$(echo "$new_name" | sed 's/^[^a-zA-Z]*//' | sed "s/\.$ext$//" | sed 's/[^a-zA-Z0-9 -]*$//')

    if [[ -z "$new_name" ]]; then
        return 1
    fi

    local name_kebab
    name_kebab=$(to_kebab_case "$new_name" | cut -c1-60)

    local target
    target=$(get_unique_path "$(dirname "$filepath")" "$name_kebab" "$ext")
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

        # Try all renameable file types
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
            docx|doc|txt|rtf|md)
                if ai_rename_document "$file"; then
                    ((renamed++))
                fi
                ;;
        esac
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "$renamed"
}

# Extract zips to Downloads root (before organizing)
extract_zips() {
    local extracted=0
    local limit="${1:-5}"
    local max_zip_size=$((100 * 1024 * 1024))  # 100MB max

    while IFS= read -r -d '' zipfile; do
        [[ -f "$zipfile" ]] || continue
        [[ $extracted -ge $limit ]] && break

        local filename
        filename=$(basename "$zipfile")
        [[ "$filename" == .* ]] && continue

        # Only process .zip files
        [[ "${filename##*.}" == "zip" ]] || continue

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

        # Move extracted files to Downloads root
        local file_count=0
        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue
            local extracted_filename
            extracted_filename=$(basename "$file")
            [[ "$extracted_filename" == .* ]] && continue
            [[ "$extracted_filename" == "__MACOSX" ]] && continue

            local target="$DOWNLOADS_DIR/$extracted_filename"
            # Add counter if file exists
            local counter=2
            while [[ -e "$target" ]]; do
                local base="${extracted_filename%.*}"
                local ext="${extracted_filename##*.}"
                if [[ "$base" == "$ext" ]]; then
                    target="$DOWNLOADS_DIR/${extracted_filename}-${counter}"
                else
                    target="$DOWNLOADS_DIR/${base}-${counter}.${ext}"
                fi
                ((counter++))
            done

            mv "$file" "$target" 2>/dev/null && ((file_count++)) || true
        done < <(find "$extract_dir" -type f -print0 2>/dev/null)

        # Cleanup
        rm -rf "$extract_dir"

        if [[ $file_count -gt 0 ]]; then
            log "    -> $file_count files extracted to Downloads"
            # Trash the original zip after successful extraction
            mv "$zipfile" "$TRASH_DIR/" 2>/dev/null || true
            ((extracted++))
        fi
    done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

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

    # Step 1: Extract zips to Downloads root
    local zips_extracted
    zips_extracted=$(extract_zips 5)

    # Step 2: Dedupe (catches original files + extracted zip contents)
    local dupes
    dupes=$(deduplicate_files)

    # Step 3: AI rename generic files BEFORE organizing (if models available)
    local renamed=0
    if [[ "$use_ai" == "true" ]] && [[ -n "$has_text_model" || -n "$has_vision_model" ]]; then
        renamed=$(ai_rename_files "$rename_limit")
    fi

    # Step 4: Organize/move files (with AI-renamed names)
    local moved
    moved=$(organize_files "$use_ai")

    log "Done: $moved organized, $dupes dupes, $zips_extracted zips, $renamed renamed"
    echo "Done: $moved organized, $dupes dupes, $zips_extracted zips, $renamed AI-renamed"
}

main "$@"
