# SnapSmith

A macOS menu-bar app for taking good-looking screenshots: capture an area or window, mark it up, hide sensitive text, and copy a polished image, all on-device.

- **Capture** an area or window with global shortcuts, or copy text out of the screen with OCR.
- **Beautify**: place the capture on a gradient, wallpaper or picture background with padding, rounded corners, a shadow, an aspect ratio (16:9, 1:1, 4:5…) and an optional watermark.
- **Mark up** with text, arrows and shapes.
- **Redact**: automatically hide emails, credit-card numbers, IP addresses and API keys, then fix mistakes by hand.
- **Private**: capture, OCR and rendering happen locally using macOS frameworks. Nothing is uploaded.

Requires macOS 11 or later (macOS 13 for "Open at Login") and a Swift toolchain (Xcode or the Command Line Tools).

## Install and run

```sh
./scripts/make-signing-cert.sh   # once, optional: local code-signing certificate (asks for your password)
./scripts/bundle.sh              # builds build/SnapSmith.app
open build/SnapSmith.app
```

On first launch, allow **SnapSmith** under System Settings → Privacy & Security → Screen Recording, then relaunch it. Without that permission macOS returns only the desktop wallpaper.

The certificate step is optional but recommended. It makes macOS identify the app by bundle ID + certificate instead of its exact code hash, so the Screen Recording permission survives rebuilds. Without it, `bundle.sh` signs ad-hoc and every code change needs the permission granted again. The certificate is self-signed, lives only in your login keychain, and is trusted for code signing for your user only. To remove it, delete "SnapSmith Local Signing" in Keychain Access.

`swift run SnapSmith` works for development too, but then macOS asks for permission on behalf of your terminal, and "Open at Login" is hidden.

## Usage

| Shortcut | Action |
| --- | --- |
| ⌥⇧4 | Capture an area (press Space to switch to window picking) |
| ⌥⇧5 | Capture a window |
| ⌥⇧3 | Capture an area and copy it straight away, without the preview |
| ⌥⇧2 | Capture an area and copy its text (on-device OCR) |

These are the defaults. Change them in **Shortcuts…** (menu bar menu): click a shortcut, press the new keys (with ⌘, ⌥ or ⌃), Esc to cancel, Delete to turn it off. Shortcuts macOS already uses (⇧⌘3/4/5, ⌘Space, and anything else enabled in System Settings → Keyboard → Keyboard Shortcuts) are refused. macOS doesn't let apps see each other's shortcuts, so if one doesn't respond, another app probably has it.

Area and window captures open in a **preview window**:

- **Copy** (⌘C or Return) copies the image, styled if Beautify is on. **Save…** (⌘S) saves a PNG (defaults to the Desktop). **Close** (Esc) closes without copying.
- The quick toggles (**Beautify**, **Inset**, **Padding**, **Redact**) are sticky: they become the defaults for the next capture. **Style…** opens the full style settings.
- **Close after copy** (on by default): the window closes after Copy.

**Markup tools** sit in the preview's toolbar. Press a tool's number key again to change its variant:

| Key | Tool | Variants |
| --- | --- | --- |
| 1 | Text: click, type, Return | small, normal, big |
| 2 | Arrow: drag from tail to tip | straight, curved left, curved right |
| 3 | Redact: click a block to show its text again, click any word to hide it, drag to draw a box | — |
| 4 | Shape: drag | rectangle, rounded, oval, line |

Esc leaves the tool (with no tool active, Esc closes the window); ⌘Z undoes markup and redaction changes. While a tool is active the preview shows the plain capture so clicks land exactly. Markup resets with each new capture.

**Redact** hides sensitive text before anything is copied or saved. SnapSmith reads the capture's text on-device and covers matches with solid blocks; the status next to the checkbox shows how many were hidden (hover for the list). Copy and Save wait for the scan to finish, so an unredacted image never reaches the clipboard. Choose categories (emails, credit cards, IP addresses, API keys) and the block colour in Style Settings. Credit-card numbers must pass the Luhn check, and IPv6 candidates must parse as real addresses, to cut false positives. Detection is best-effort: always look at the result before sharing something sensitive.

Text captures (⌥⇧2) go straight to the clipboard. The menu bar icon briefly shows a checkmark after each copy.

From the menu bar menu:

- **Beautify Captures**: the same switch as the preview window's Beautify checkbox.
- **Style Settings… (⌘,)**: padding, rounded corners, shadow, background (gradient, desktop wallpaper, or a picture), colours and angle, aspect ratio, watermark text, inset and balance, Close after copy, Auto-redact, and archive retention, with a live preview of your latest capture.
- **Shortcuts…**, **Open Archive Folder**, **Screen Recording Settings…**, **Open at Login** (macOS 13+, bundled app only).

Files go to `~/Library/Application Support/SnapSmith/Archives/`: `Raw/` holds the original captures, `Output/` holds the processed versions. Captures older than 3 days are moved to the Trash automatically (at launch, after each capture, and hourly). Change the number of days, or turn it off, under Style Settings → **Delete captures after … days**. Only SnapSmith's own `SnapSmith-*.png` files in `Raw/` and `Output/` are affected; files saved with **Save…** are never touched.

## How it works

- **Capture** runs Apple's `/usr/sbin/screencapture` (`-i -o -a`, plus `-w` for windows) and lets it draw the selection UI. The image goes to a temp file, so your clipboard isn't touched mid-capture.
- **Hotkeys** use Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
- **OCR** uses Vision's `VNRecognizeTextRequest`; word and match positions come from `VNRecognizedText.boundingBox(for:)`.
- **Rendering** is Core Graphics: redact, then markup, then beautify. Lengths are in points and scaled by the capture's pixel density, so Retina captures keep their proportions.

## Layout

- `Sources/CaptureKit/`: the testable core: `ScreenCapturer`, `HotKey`, `Shortcut`, `Beautifier`, `Inset`, `Redactor`, `RedactionEdits`, `Annotation`, `Pipeline`, `TextRecognizer`, `StyleStore`, `Preferences`, `ArchiveCleaner`
- `Sources/SnapSmith/`: the menu-bar app, preview window, style window and shortcut recorder
- `Tests/CaptureKitTests/`: XCTest suite (`swift test` needs full Xcode; the Command Line Tools don't ship XCTest)
- `scripts/`: `bundle.sh` (builds and signs the `.app`) and `make-signing-cert.sh`

## Limitations

No tilt/3D effect, no moving or resizing markup after it's drawn (use ⌘Z and redraw), and markup is a fixed red.

## License

MIT. See [LICENSE](LICENSE).
