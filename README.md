# Downloads Organizer

AI-powered file organization for macOS. Automatically deduplicates, categorizes, and renames files in your Downloads folder using local LLMs via Ollama.

## Features

- **Deduplication** - Trashes files with identical md5 hashes (keeps newest)
- **Smart Categorization** - Moves files to typed folders (Invoices/, Images/, Documents/, etc.)
- **Kebab-case Renaming** - Normalizes filenames, adds date suffix to invoices
- **AI Image Renaming** - Uses moondream vision model to name generic images
- **AI PDF Renaming** - Extracts text + uses llama3.2 to name generic PDFs
- **Zip Extraction** - Auto-extracts archives and organizes contents
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

## Auto-Run Setup (Folder Action)

1. Open **Automator** (Cmd+Space → "Automator")
2. Create new **Folder Action**
3. Set folder to **Downloads**
4. Add **Run Shell Script** action:
   - Shell: `/bin/bash`
   - Pass input: `as arguments`
   - Code:
     ```bash
     sleep 5
     ~/Downloads/.organize/ai-organize.sh true 5
     ```
5. Save as "Organize Downloads"

To disable: Delete `~/Library/Workflows/Applications/Folder Actions/Organize Downloads.workflow`
