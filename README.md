# ClipVault

![ClipVault](docs/heading.png)

A secure, privacy-focused clipboard manager for macOS with AES-256-GCM encryption.

## Features

- **Automatic clipboard monitoring** - Captures all clipboard changes in real-time
- **AES-256-GCM encryption** - All content encrypted at rest with keys in macOS Keychain
- **Smart content filtering** - Auto-detects and excludes passwords, API keys, SSH keys, credit cards
- **Rich text support** - Preserves bold, italic, colors, and formatting
- **Image and screenshot history** - Retains PNG, TIFF, and JPEG clipboard images with encrypted storage and thumbnail previews
- **Source app tracking** - See which app each item came from with native icons
- **Pin important items** - Keep frequently used snippets at the top
- **Real-time search** - Instantly filter clipboard history
- **Auto-paste** - One-click paste without keyboard commands

## Installation

### Homebrew (Recommended)

```bash
brew install eddmann/tap/clipvault
```

### Manual Download

1. Download the latest release from [GitHub Releases](https://github.com/eddmann/ClipVault/releases)
2. Move `ClipVault.app` to Applications
3. Double-click to open

The app is **signed and notarized** by Apple.

## Screenshots

<p align="center">
  <img src="docs/menu-with-history.png" width="400" alt="Menu with clipboard history" />
</p>

<p align="center">
  <em>Quick access from the menu bar with pinned items and recent history</em>
</p>

<p align="center">
  <img src="docs/history-window.png" width="700" alt="Clipboard history window" />
</p>

<p align="center">
  <em>Full clipboard history window with search, app filtering, and actions</em>
</p>

## Usage

- Click the menu bar icon to view recent clipboard history and pinned items
- Use real-time search to instantly find any item you're looking for
- Click an item to copy it, or select "View All Clipboard History" to browse your complete history

## Requirements

- macOS 14.0 (Sonoma) or later
- Universal Binary (Intel + Apple Silicon)

## Security

- All content encrypted at rest (AES-256-GCM)
- Encryption keys stored in Keychain with device-only access
- No network transmission or telemetry
- Popular password managers excluded by default

### Image storage and metadata privacy

Settings → General includes an image storage limit, default **1 GB** (1,000,000,000 bytes). It counts saved encrypted image bytes. When full, the oldest unpinned images are deleted first; recopying an image does not reset its FIFO age. Pinned images count toward the limit and are preserved. New images are rejected if pinned images leave insufficient space. Existing pins exceeding the default remain readable; raise the limit or remove/unpin them. Lowering the limit below pinned usage is rejected.

The limit excludes database overhead and backups. Freed database pages are reused and compacted when the store opens; physical file size need not drop immediately.

App identifiers, timestamps and image format metadata are authenticated and encrypted. Deduplication uses keyed HMAC indexes, with each index also authenticated inside its row's encrypted metadata. Existing stores convert transactionally using the existing Keychain key, preserving content ciphertext, IDs and pins. Metadata is bound to its clip UUID. A missing key or invalid ciphertext fails closed; decryption never creates a replacement key.

This is field encryption, not whole-database encryption: row counts, ciphertext sizes, opaque IDs and pin flags remain visible. Old backups and previously collected logs may retain legacy metadata.
