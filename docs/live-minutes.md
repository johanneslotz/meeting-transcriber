# Live Minutes

A window that shows, while a meeting is being recorded, the live transcript and a rolling summary of the meeting: topics, decisions, tasks (with owner and due date when stated) and open questions. It is a proof of concept.

Everything stays on the Mac when the summary endpoint is local (the default points at the protocol provider's endpoint, typically Ollama or LM Studio on localhost). Settings warns when the resolved endpoint is not localhost.

## Turning it on

Settings, Transcribe, section **Live Minutes (PoC)**:

| Setting | Default | Meaning |
|---|---|---|
| Show live minutes during recording | off | Master switch. Needs **Enable live transcription during recording** in the section above, because the minutes are built from the live captions. |
| Open window when a recording starts | on | Opens the window without taking focus from the meeting app. The menu bar item **Live Minutes...** opens it at any time while the feature is on. |
| Update every | 90 s | Summary refresh interval, 30 to 300 s. |
| Visible in screen sharing | off | Maps to `NSWindow.sharingType`: off is `.none` (screen shares and captures cannot see the window), on is `.readOnly`. Applies immediately. |
| Endpoint, Model | empty | Empty fields use the protocol provider's OpenAI-compatible endpoint and model. |

The protocol API key is sent only when the summary goes to the same endpoint the protocol provider uses. A separately configured endpoint never receives it.

## The window

The left pane streams the finalized utterances with their speaker labels. **Show transcript** hides it, so the summary can be read without scrolling text; utterances keep arriving while it is hidden. The right pane shows the four sections, a banner that the content is an automatic draft, the time of the last update (`Last updated hh:mm:ss`) and an **Updating** indicator while a request runs.

When the recording ends, the engine folds in the remaining utterances with one last update, and the pane offers **Copy draft** and **Save draft...** (Markdown, through a save panel). Nothing is written unless you choose a destination, and the draft never touches the protocol output of the normal pipeline.

## How the summary is built

`LiveCaptionsState.onFinalized` is the single subscription point for finalized utterances, so Live Minutes sees exactly what the caption overlay sees. There is no second ASR pass, and the recorder, the WAV writing, diarization and crash recovery are not involved.

`LiveMinutesEngine` (an actor) keeps the running state as JSON. An update sends the current state and only the utterances that arrived since the last successful update, newest first up to 6000 characters, and replaces the state with the validated reply. Updates run every `Update every` seconds, or after 12 pending utterances, whichever comes first; the count trigger is debounced to at most one update per 20 s.

- One request at a time. A trigger that finds a request running is skipped; the utterances stay pending for the next update.
- A transport error, a reply that is not the expected JSON, or a reply that would empty a non-empty state keeps the previous summary and the pending utterances. The window notes that the last update failed.
- Stopping cancels the running request and discards its reply.
- The pending queue is capped (400 utterances) and each state section is capped (40 items of 280 characters), so requests stay bounded however long the meeting runs or the endpoint is down.

The prompt is `live_minutes_prompt.md` in `~/Library/Application Support/MeetingTranscriber/`, with the same mechanism as `protocol_prompt.md`: a non-empty file replaces the built-in default, and `{LANGUAGE}` is replaced by the protocol language from Settings. The reply must keep the JSON schema in the default prompt.

## Privacy

- Transcript and summary live in memory only. Nothing is written while the meeting runs, and the log carries counts, never content.
- The only network traffic is the chat completion requests to the configured endpoint.
- Closing the window only hides it. The content stays in memory until the next recording starts, or until the app quits.

## Comparing with the protocol

The draft and the protocol of the normal pipeline are independent. To compare them, save the draft after the meeting and put it next to the protocol the pipeline writes into the output folder. Differences come from the inputs (live captions against the full transcription and diarization) and from the update scheme (incremental state against one pass over the whole transcript).

## Manual check with the meeting simulator

1. Enable live transcription and Live Minutes, set the interval to 30 s, point the endpoint at a local model.
2. Start `tools/meeting-simulator` and a recording of it.
3. The transcript streams in, and the summary updates about every 30 s.
4. With Little Snitch or `nettop -m tcp -p MeetingTranscriber`, expect connections only to the configured endpoint.
5. Compare the file listing of the recordings and output folders before and after the meeting: no new files appear until the recording stops and the normal pipeline writes its own.

## Not included yet

A mode without audio files, speaker naming during the meeting, translation, and editing the summary. The coordinator takes lines from `LiveCaptionsState.onFinalized` and has no reference to the recorder, so a live-only mode can drive `begin()` and `end()` itself.
