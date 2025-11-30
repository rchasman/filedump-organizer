# Downloads Organizer

AI-powered file organization for macOS. Automatically deduplicates, categorizes, and renames files in your Downloads folder using local LLMs via Ollama.

## Features

- **Zip Extraction** - Auto-extracts archives to Downloads root (before organizing)
- **Deduplication** - Trashes files with identical md5 hashes (keeps newest)
- **AI Image Renaming** - Uses moondream vision model to name generic images
- **AI PDF Renaming** - Extracts text + uses llama3.2 to name generic PDFs
- **Smart Categorization** - Moves AI-renamed files to typed folders (Invoices/, Images/, Documents/, etc.)
- **Kebab-case Renaming** - Normalizes filenames, adds date suffix to invoices
- **Log Rotation** - Auto-rotates logs over 1MB

## Folder Structure

```
~/Downloads/
├── Invoices/    # PDFs with invoice/receipt keywords (suffixed mon-yy)
├── Images/      # png, jpg, jpeg, webp, gif, svg, heic
├── Documents/   # pdf, docx, pptx, txt, md
├── Data/        # csv, xlsx, xls, json
├── Code/        # zip, dmg, pkg, exe, vsix
├── Media/       # mp4, mov, mp3, wav
├── Resumes/     # Files with resume/cv in name
└── Misc/        # Everything else
```

## Requirements

- macOS
- [Ollama](https://ollama.ai) with models:
  - `llama3.2` - text categorization and PDF naming
  - `moondream` - image description
- `pdftotext` (optional, for PDF renaming): `brew install poppler`

## Usage

```bash
# Full run with AI renaming (up to 10 files)
~/Downloads/.organize/ai-organize.sh

# Rename more files
~/Downloads/.organize/ai-organize.sh true 50

# Fast mode (no AI, extension-based only)
~/Downloads/.organize/ai-organize.sh false
```

## Workflow Order

1. **Extract zips** - Unzips archives to Downloads root
2. **Deduplicate** - Removes duplicate files
3. **AI rename** - Gives descriptive names to generic files
4. **Organize** - Moves renamed files to categorized folders

## Auto-Run Setup (Folder Action)

1. Compile the script:
   ```bash
   mkdir -p ~/Library/Scripts/Folder\ Action\ Scripts
   osacompile -o ~/Library/Scripts/Folder\ Action\ Scripts/organize-downloads.scpt organize-downloads.applescript
   ```

2. Open **Folder Actions Setup** (Cmd+Space → "Folder Actions Setup")
3. Enable Folder Actions (checkbox at top)
4. Click **+** to add Downloads folder
5. Choose **organize-downloads.scpt** from the list

Enable Folder Actions via CLI:
```bash
osascript -e 'tell application "System Events" to set folder actions enabled to true'
```
