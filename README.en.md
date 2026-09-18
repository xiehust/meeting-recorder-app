# MeetingRecord · macOS

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md)

A native SwiftUI menu bar app based on the [PRD](PRD.md). **0.6.0 is a development preview** with Chinese, English, and Japanese interfaces, live transcription, post-meeting audio review, AI proofreading, and customizable summaries. It does not yet implement the entire PRD.

## Interface language

Open **Settings → Interface language** and choose **Follow system**, **简体中文**, **English**, or **日本語**. Changes apply immediately and save automatically, including the main window, menu bar panel, and open app dialogs. Follow system is the default.

The first supported language in the system preference list is used; otherwise the app falls back to English. Chinese regional variants use Simplified Chinese. Built-in template names, instructions, and section previews are translated. Meeting content, custom templates, names, edits, and historical versions stay unchanged.

Interface language is independent of recognition and summary language. **Live and batch recognition support Chinese, Japanese, English, legacy Chinese/English mixed mode, and a new Chinese/Japanese/English mixed mode. Summary output and custom vocabularies support all three languages.** Changing the interface does not change these saved options or translate historical summaries. macOS-managed menus, file panels, permission prompts, and Finder names follow system language settings. See [localization details](docs/LOCALIZATION.md) (Chinese).

Japanese and multilingual processing parameters, tests, and live AWS checks are documented in [Japanese validation](docs/JAPANESE-VALIDATION.md) (Chinese).

## Build and run

Requires macOS 26 and Xcode Command Line Tools / Swift 6.2 or later. The project uses native Swift Package Manager; full Xcode is not required. The first build downloads the AWS SDK and needs network access and several GB of cache space.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/MeetingRecord.app
```

To build a separate app:

```sh
bash scripts/build-app.sh debug dist/MeetingRecord-0.6.0.app
```

Start recording from the packaged `.app`, which includes macOS permission declarations and localization resources. `swift run` is not a substitute for installation and permission testing. Builds use ad hoc local signing; distribution signing, notarization, and stable permission identity are not implemented yet.

The scripts prefer an installed macOS 26 SDK and handle Swift Testing plugin discovery with Command Line Tools. On the development machine, SDK 27 requires SwiftUI macro plugins not included with Command Line Tools, so use these scripts.

## Features

- Main window, menu bar controls, meeting history, and transcript search.
- Select a running **Teams, Zoom, Feishu / Lark, Tencent Meeting, or DingTalk** macOS client, microphone, recognition language, cloud transcription, and audio caching. All detected supported clients are listed; the user chooses which to record.
- Core Audio Process Tap captures the selected application and verified audio helpers inside its bundle. AVAudioEngine captures the microphone separately. Browser meetings are not supported.
- Independent audio levels and states, pause/resume, and a manual microphone mute. This app does **not** automatically follow Teams or Zoom mute. Closing the window leaves it running; quitting prompts when work is active.
- Two AWS Transcribe Streaming sessions: 16 kHz, 16-bit mono PCM in 100 ms chunks. Mixed recognition uses `IdentifyMultipleLanguages` with `zh-CN,en-US` or `zh-CN,en-US,ja-JP`; fixed-language modes use their language codes. The remote stream requests speaker labels.
- Partial results update in place. Final results are deduplicated and saved with immutable originals, separate manual revisions, speaker details and merges, segment attribution, notes, and highlights.
- SQLite WAL storage and visible warnings for gaps, disconnections, incomplete final results, cache failures, and interruptions. Finalization waits up to 12 seconds.
- Markdown / TXT transcript exports, an interactive sample requiring no recording, and AI version exports. Markdown citations use links to explicit HTML anchors; the viewer must support them.
- Conservative AI proofreading with per-change review and **Accept all**. Manual transcript edits are protected, sensitive wording needs confirmation, and punctuation changes can be undone.
- Template-based summaries with validated source citations, version selection, stale-input warnings, manual edits saved as new versions, and retry from saved proofreading chunks or the summary stage.
- Global Chinese/Japanese/English Transcribe vocabulary management, bulk paste, AWS sync status, content-versioned snapshots, and cleanup of unreferenced versions.
- Optional post-meeting batch transcription with review before adoption. Originals, manual edits, and historical AI results remain available.

## Suggested workflow

1. Configure your AWS profile and regions in Settings. If needed, add vocabulary and sync until READY.
2. Join a meeting in a supported desktop client. Choose the app and microphone, review the capture/cloud scope, and start recording.
3. Add participant details, terminology, and notes before proofreading. These provide context; notes are not evidence of spoken remarks.
4. Optionally use **Audio review** to upload retained recordings for batch transcription. Compare results, then adopt a version or restore the live transcript. Speaker labels and manual edits do not automatically transfer between versions.
5. Proofread, review suggestions, choose a summary template, and generate or export a summary. Existing versions are preserved.

Automatic proofreading and summarization can be disabled in Settings. Batch retranscription is **manual by default**; select automatic mode to run it after new recordings. Automatic batch mode retains audio and takes priority over automatic AI processing: it waits for review/adoption before AI continues. Each meeting can override this before recording.

Batch uploads use a configured same-region S3 bucket, falling back to the global vocabulary bucket if the dedicated bucket is blank. Jobs can be queried again after interruption. Cleanup is attempted after results are saved; failures retain a retry option. Stopping local waiting may leave AWS jobs running and billing. See [batch transcription](docs/BATCH-TRANSCRIPTION.md) (Chinese).

## Summary templates

| Template | Focus |
| --- | --- |
| Meeting minutes | Discussion, confirmed decisions, action items, and open questions |
| Interview notes (interviewer) | Candidate experience, Q&A, job-related evidence, demonstrated strengths, follow-up questions, agreed next steps |
| Training notes | Objectives, knowledge framework, concepts, procedures, examples, learner Q&A, practice, missing information |

Select a template before recording or on the proofreading/summary pages. Set a default in Settings. **Manage templates → New template** lets you define a name, requirements, overview title, and up to 16 ordered sections. Section kinds are points, decisions, actions with owners/dates, and open questions. Built-ins are read-only and can be duplicated.

The template library is local (`summaryTemplateLibrary` in preferences). Meetings and generated versions save complete template snapshots. Editing or deleting a template does not rewrite historical records. Custom section titles are used verbatim. Built-in output titles follow the saved summary language, independently of the interface preview language.

Template requirements are sent to Bedrock only when generating. Templates cannot override factual accuracy, source citation, or manual-note separation rules. Interview templates do not infer hiring decisions or evaluate sensitive personal traits.

## AWS and data

- Defaults: AWS profile `default`, region `us-west-2`. Transcribe region and the two AI stage configurations are independently configurable.
- AI uses `https://bedrock-runtime.{region}.amazonaws.com/openai/v1/responses`, SigV4 service `bedrock`, and `global.openai.*` inference profiles for Astra, Sol, Terra, and Luna. AWS may route globally from the selected ingress region. Historical endpoint metadata is preserved.
- All four Runtime models passed real connection checks in 0.5.1. Availability still depends on account permissions and supported access location. Models, regions, and reasoning effort are not silently switched or retried. See [Runtime integration](docs/BEDROCK-RUNTIME.md) (Chinese).
- SDK profile credentials are resolved locally; the app does not store AWS keys or log request bodies. HTTP redirects are disabled.
- Live transcription sends both audio streams to AWS and bills them separately. Batch transcription uploads retained recording files to S3 and incurs additional charges. App launch and sample browsing do not call transcription or inference.
- AI receives final transcript text, participant information, terminology, and relevant notes. Requests use `store: false`; this disables Responses conversation storage, not all cloud logs or service retention.
- Vocabulary sync uploads phrases and display forms to an existing same-region S3 bucket. Local vocabulary notes are not uploaded. Only READY versions are used for new recordings. See [vocabulary setup and permissions](docs/CUSTOM-VOCABULARY.md) (Chinese).
- Local data lives in `~/Library/Application Support/MeetingRecord/`. Database and cache directories are restricted to the current user; no additional database encryption is implemented.
- A fresh installation starts with audio caching off. The saved preference is respected. When enabled, audio remains until the meeting is deleted; automatic expiration is not implemented.
- Deleting a local meeting removes local audio, transcripts, and notes, not cloud data. Clean up outstanding batch resources first; S3 versioning may retain older object versions.

Read-only environment checks:

```sh
python3 scripts/check-environment.py
python3 scripts/check-environment.py --aws --profile default --region us-west-2 --output docs/environment.json
```

Checks do not record audio, call inference, or save account IDs or credentials. Successful terminal STS or model-catalog access does not prove all GUI credentials or model permissions work.

## Known limits and validation

Teams headphone capture and dual-source transcription were user-verified. Real Zoom, Feishu, Tencent Meeting, and DingTalk calls, mixed-language speaker separation, device switching, speakerphone echo, and two-hour stability still need further validation. See [M0 validation](docs/M0-VALIDATION.md) and [Teams audio fix](docs/TEAMS-AUDIO-FIX.md) (Chinese).

After a network outage, audio can keep caching with marked gaps, and retained audio can be submitted for batch transcription. Automatic stream reconnection, playback, and cache expiration are not implemented. Pause/resume to reconnect. A single cached file over four hours is not supported for batch transcription. Failures preserve existing results but do not guarantee transcript completeness.

## Project structure

```text
Sources/MeetingCore        Models, immutable originals, edits, templates, SQLite, exports, localization
Sources/MeetingAudio       App audio taps, microphones, PCM conversion, local cache
Sources/MeetingCloud       Transcribe streaming/batch, vocabulary, Bedrock Responses, validation
Sources/MeetingRecordApp   SwiftUI, menu bar, recording lifecycle
Sources/MeetingAIValidate  Explicit model/recording validation CLI
Tests                     Core, audio, cloud, and localization tests (no AWS calls)
Resources                 Icon, localized permission strings, signing configuration
scripts                   Build, test, read-only environment checks
docs                      Feature details and validation records
```

There is no CodeGraph index. Use it for code navigation only if a `.codegraph/` directory is created. Icon source and licensing: [icon notes](Resources/IconSource/README.md).

After building, `.build/out/Products/Debug/MeetingAIValidate --probe-models` checks four models using short fixed text with no meeting content, stopping at the first error. `--latest` or `--meeting UUID` sends a real meeting to its configured AWS model and saves results: use only with explicit authorization and quit the desktop app first. `--summary-only` retries only summarization. Release history is available in the [Chinese README](README.md).
