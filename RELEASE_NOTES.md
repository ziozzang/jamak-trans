First release of Jamak Trans, an on-device SRT subtitle translator for macOS 26+.

- Drag & drop `.srt` files or folders (recursive); per-file source language detection; files already in the target language are skipped
- Parallel, queued translation with overall and per-file sentence progress, rate and ETA
- Output: translation only or bilingual (original in gray), SRT or SMI; `name.ko.srt` or keep the name and back up the original as `.org`
- Checkpointed resume after interruption, session restore on launch, work-list export/import
- Self-update from GitHub Releases with SHA256SUMS verification

Downloaded with a browser? Run `xattr -dr com.apple.quarantine /Applications/JamakTrans.app` once (ad-hoc signed, not notarized).
