---
name: whisperm8-clipboard
description: Read the user's clipboard history (WhisperM8 replaces Maccy) with `whisperm8 clipboard`. Use whenever the user refers to something they copied instead of pasting it again, in English or German, for example "what I copied", "the error I copied earlier", "from my clipboard", "the link from before", "the screenshot I copied", "was ich kopiert habe", "aus der Zwischenablage", "den Fehler von vorhin", "der Link von eben". NOT for transcription (whisperm8-transcription) or chat management (whisperm8-chats).
---

# Clipboard history (`whisperm8 clipboard`)

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
whisperm8 clipboard copy 2                  # put entry 2 back on the clipboard (app must run)
```

- Numbers follow the newest-first order of `list` (pinned entries count where
  they belong in time). An ID or a unique prefix of at least 4 characters works too.
- `get` on an image returns the absolute path of a PNG file: open it with Read.
  On files it returns their paths.
- Typical secrets (API keys, tokens, JWTs, private keys, passwords in
  assignments and `.env` lines) come back as `[REDACTED:…]`. Do not try to
  work around that and do not ask the user to switch masking off for you.
- Exit 1 with a message means the history is off or the user blocked agent
  access. Tell the user where to switch it on (Settings > Clipboard), do not retry.
  Exit 3 means no such entry.

## JSON fields

`list` and `search` return an array of objects:
`number`, `id`, `kind` (`text` | `image` | `files`), `pinned`, `copiedAt`
(ISO 8601), `preview` (masked), `sourceApp`, `sourceBundleID` (when known),
plus `chars` for text, `imagePath`, `width`, `height` for images and `files`
for file entries.

`get --json` adds for text: `text`, `totalChars`, `from`, `truncated`,
`nextFrom` (only when truncated) and `secretsMasked`.
