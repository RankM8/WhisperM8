---
name: clipboard
description: Clipboard history of the user (WhisperM8 replaces Maccy), including finished dictations and their raw transcripts. Use whenever the user refers to something they copied or dictated instead of pasting it again, in English or German, for example "what I copied", "the error I copied earlier", "from my clipboard", "the link from before", "the screenshot I copied", "what I dictated earlier", "was ich kopiert habe", "aus der Zwischenablage", "den Fehler von vorhin", "der Link von eben", "was ich vorhin diktiert habe". Also when the user invokes /whisperm8:clipboard directly. NOT for transcribing files (whisperm8-transcription) or chat management (whisperm8-chats).
---

# Clipboard history (`whisperm8:clipboard`)

WhisperM8 keeps a searchable clipboard history when the user switches it on
(Settings > Clipboard). When the user mentions something they copied, read it
here instead of asking them to paste it.

Inside Claude Code chats started by the WhisperM8 app, the `clipboard` tool
(`mcp__whisperm8__clipboard`) does the same and is the first choice. Use the
CLI below everywhere else (plain terminal, Codex, scripts).

```bash
whisperm8 clipboard status --json           # is it on, may agents read it?
whisperm8 clipboard list --limit 10 --json  # newest first, number 1 is the newest entry
whisperm8 clipboard search "stack trace"    # every word must match, case-insensitive, full text
whisperm8 clipboard get 2 --json            # full text in chunks of 50,000 characters
whisperm8 clipboard get 2 --from 50000      # next chunk (nextFrom in the JSON)
whisperm8 clipboard get 2 --max-chars 0     # everything at once
whisperm8 clipboard get 1 --original        # raw transcript of a rewritten dictation
whisperm8 clipboard copy 2                  # put entry 2 back on the clipboard (app must run)
```

- Numbers follow the newest-first order of `list` (pinned entries count where
  they belong in time). An ID or a unique prefix of at least 4 characters works too.
- Finished dictations are in the history too (`dictationMode`, for example
  `Slack`). For "what I dictated earlier" search or list them. When
  `hasOriginal` is true the mode rewrote the text; `get --original` returns
  what the user actually said.
- `get` on an image returns the absolute path of a PNG file: open it with Read.
  On files it returns their paths.
- Typical secrets (API keys, tokens, JWTs, private keys, passwords in
  assignments and `.env` lines) come back as `[REDACTED:…]`. Do not try to
  work around that and do not ask the user to switch masking off for you.
- Exit 1 with a message means the history is off or the user blocked agent
  access. Tell the user where to switch it on (Settings > Clipboard), do not retry.
  Exit 3 means no such entry.

## When the user invokes this skill directly

`/whisperm8:clipboard` with or without text after it. Work out what they want
and answer right away, without asking back:

- **Nothing after it:** show the 10 newest entries as a short numbered list
  (number, one-line preview, source app or dictation mode, age). Offer nothing
  else; the user picks a number next.
- **Words after it** ("stripe webhook", "der Link von Jonas"): search, then
  show the hits the same way. One clear hit: show its full text right away.
- **A number** ("3", "nimm 3"): `get` it and show the full text (or open the
  image with Read).
- **Dictations** ("diktate", "was hab ich diktiert"): list and keep only
  entries with `dictationMode`. "Original" or "was hab ich gesagt": use
  `get --original` on that entry.
- **"Kopier 3" / "leg 3 zurück"**: `copy 3`, then say it is on the clipboard.
- **A task with it** ("fix the error I copied", "fass den Link zusammen"):
  fetch the entry and do the task; do not stop at showing it.

Keep previews on one line and do not dump long texts unasked. Masked secrets
stay masked.

## JSON fields

`list` and `search` return an array of objects:
`number`, `id`, `kind` (`text` | `image` | `files`), `pinned`, `copiedAt`
(ISO 8601), `preview` (masked), `sourceApp`, `sourceBundleID` (when known),
plus `chars` for text, `imagePath`, `width`, `height` for images and `files`
for file entries. Dictations add `dictationMode` and, when rewritten,
`hasOriginal`.

`get --json` adds for text: `text`, `totalChars`, `from`, `truncated`,
`nextFrom` (only when truncated), `secretsMasked` and `source`
(`result` or `original`).
