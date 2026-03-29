# AI Keyword Generator (Lightroom Plugin)

## Overview

AI Keyword Generator is a Lightroom plugin designed to automate and streamline keywording using **local AI**. It analyzes your images, learns from your existing keyword patterns, and generates structured Lightroom keywords—without sending your photos to the cloud.

This tool is built for photographers who want **speed, consistency, and control** in their keywording workflow.

---

## Key Features

### 🔹 Local AI (Privacy First)

* Runs entirely on your machine using Ollama
* No cloud uploads or external APIs
* Temporary previews are deleted after processing

### 🔹 Smart Keyword Generation

* Analyzes image content (subjects, mood, scene, style)
* Learns from your existing keyword habits
* Avoids duplicate keywords already applied

### 🔹 Structured Lightroom Keywords

* Automatically builds hierarchical keywords (e.g. `People|Bride`)
* Supports Lightroom-compatible separators (`|`, `>`, `<`)

### 🔹 Full Preview Control

* Review all generated keywords before applying
* Approve/deny individual keywords
* Cancel entire operation if needed

### 🔹 Style Presets

* Create reusable keyword styles (Wedding, Portrait, Fine Art, etc.)
* Apply consistent keyword structures across shoots

### 🔹 Multiple Modes

* **Full Mode**: Metadata + mapping + quick tags
* **Metadata Only**: Camera, lens, date, season
* **AI Assist**: Local AI keyword suggestions

### 🔹 Performance Controls

* Limit number of photos per run
* Control number of AI suggestions per image
* Low-memory mode for weaker systems

---

## How It Works

1. Select photos in Lightroom
2. Choose a processing mode
3. (Optional) Select a style preset and enter quick tags
4. AI analyzes images locally
5. Keywords are generated and structured
6. Preview screen lets you approve or deny
7. Approved keywords are applied to your catalog

---

## Installation

1. Download or clone this repository
2. Open Lightroom
3. Go to:

   ```
   File > Plug-in Manager
   ```
4. Click **Add** and select the plugin folder

---

## Local AI Setup (Ollama)

This plugin uses **Ollama** to run local vision models.

### Automatic Setup

* The plugin can install Ollama automatically on first run
* It will also download a compatible vision model (e.g. `llava`)

### Manual Setup (Optional)

1. Install Ollama: [https://ollama.com](https://ollama.com)
2. Pull a model:

   ```bash
   ollama pull llava:latest
   ```

---

## Usage

### Run Keyword Generator

```
Library > AI Generate Keywords
```

### Manage Features

```
Library > Plug-in Extras >
  - Manage Style Presets
  - Manage Local AI Runtime
```

---

## Configuration

### AI Settings

* Suggestions per image (1–30)
* Max photos per run
* Low memory mode
* CPU-only mode

### Style Preset Format

```
Wedding=Event Type|Wedding,People|Bride
Portrait=Event Type|Portrait
Fine Art=Style|Fine Art
```

---

## File Structure

* `KeywordRunner.lua` – Main plugin logic
* `LocalAiRuntimeManager.lua` – AI runtime configuration
* `LocalAiSuggester.lua` – AI keyword generation logic
* `ManageStyles.lua` – Style preset management UI
* `OllamaKeywordBridge.sh/.cmd/.ps1` – Local AI bridge scripts

---

## Performance Notes

* AI processing is intentionally rate-limited for stability
* Recommended defaults:

  * 6–10 keywords per image
  * 3–10 images per run (depending on system)

---

## Limitations

* First AI run may take several minutes (model download)
* Requires internet for initial setup only
* Performance depends on hardware

---

## Roadmap

* Batch optimization improvements
* Better keyword categorization automation
* Enhanced learning from user libraries
* UI improvements for preview and filtering

---

## Contributing

Contributions, feedback, and testing are welcome.

If you're a photographer, your workflow feedback is especially valuable.


---

## Why This Exists

Keywording is one of the most tedious parts of photography workflows.

This plugin is built to:

* Save time
* Maintain consistency
* Keep full control in the photographer’s hands

---

## Contact

If you want to test, collaborate, or give feedback—reach out.
