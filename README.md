# Jamak Trans — SRT subtitle translator for macOS

English · [한국어](README_KO.md)

Jamak Trans (자막 번역, "subtitle translation") is a native macOS app that translates `.srt` subtitles with the on-device Translation framework built into macOS. Subtitle text never leaves your Mac.

## Install

Run this one line in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/ziozzang/jamak-trans/main/install.sh | sh
```

- It downloads the latest release, verifies it against `SHA256SUMS` and installs `/Applications/JamakTrans.app`.
- The app is ad-hoc signed and not notarized. Files fetched with `curl` get no quarantine flag, so it opens without a Gatekeeper prompt. Later updates come through the app's self-updater.
- If you downloaded the zip from [Releases](https://github.com/ziozzang/jamak-trans/releases) with a browser instead, macOS will say it "is damaged" or is from an unidentified developer. Run this once to fix it:

```sh
xattr -dr com.apple.quarantine /Applications/JamakTrans.app
```

Requires macOS 26 or later.

## Features

- **Input:** drag and drop files or folders onto the window or the Dock icon. Folders are scanned recursively for `.srt` files.
- **Language detection:** each file's source language is detected once, then the whole file is translated from it into the target language you pick.
- **Skipping:** a file is skipped if it is already in the target language, is bilingual (at least 30% of its sentences are in the target language), or already has an output file.
- **Queue:** files are translated in parallel (1–8 at a time), and you can pause, stop and retry. Progress is shown overall and per file ("sentence n/m"), with a rate and an ETA.
- **Output:**
  - Translation only, or translation with the original below it in gray.
  - SRT, or SMI (SAMI).
  - Naming: either write a new `name.ko.srt` next to the original, or keep the original name and rename the source to `foo.srt.org`.
- **Resume:**
  - Translated sentences are checkpointed every 40 sentences, so an interrupted file continues where it stopped.
  - The work list is restored on the next launch.
  - Work lists can be saved to and loaded from JSON files.
- **Subtitle handling:**
  - Encodings: UTF-8/16, CP949, Shift-JIS, GB18030, Big5 and Windows-1252 are detected automatically.
  - `{\an8}` position tags, whole-cue italics and dialog dashes are preserved.
- **Language models:** missing models are downloaded through the system prompt.

## Build

```sh
./build.sh           # build/JamakTrans.app (universal, ad-hoc signed); version comes from ./VERSION
./build.sh debug
```

The build calls `swiftc` directly, so the Command Line Tools are enough and Xcode isn't needed.

## Auto-update

Auto-update works the same way as in [sugyeol](https://github.com/ziozzang/sugyeol) and uses GitHub Releases.

- **When it checks:** once a day at launch, the app queries `api.github.com/repos/ziozzang/jamak-trans/releases/latest`.
  - To check by hand, use **업데이트 확인…** (Check for Updates) in the app menu.
  - To turn automatic checks off, uncheck the menu toggle or set `JAMAK_TRANS_NO_UPDATE_CHECK`.
- **Prompt:** when a newer version exists, the app shows its release notes and asks what to do: update and relaunch, later, or skip this version. It never installs without asking.
- **Install steps:**
  1. `JamakTrans_<version>_macos_universal.zip` is downloaded and hashed with SHA-256 as it arrives. The hash is checked against the release's `SHA256SUMS`.
  2. The zip is extracted, and the bundle ID and version are verified.
  3. The app quits normally, which saves the queue and checkpoints.
  4. The bundle is swapped and the app relaunches. Interrupted work can then be resumed.
- **Permissions:** the folder containing the app must be writable.

## Release process

GitHub Actions are not used; releases are built and published by hand.

```sh
echo 1.0.1 > VERSION            # single source of the version
scripts/release.sh              # dist/JamakTrans_1.0.1_macos_universal.zip + dist/SHA256SUMS (verified)
scripts/release.sh --publish    # push tag v1.0.1 and create the GitHub release (gh or $GITHUB_TOKEN; notes from RELEASE_NOTES.md)
```

## License

MIT
