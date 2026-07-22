#!/bin/bash
# managed-by: whisperm8-statusline
#
# WhisperM8-Subagent-Statusline für Claude Code — überschreibt nur Tasks,
# deren tatsächlich verwendetes Modell bereits aufgelöst wurde.
# Benötigt: jq.

input=$(cat)

# Ohne jq oder bei leerem/ungültigem Input bleibt Claude Codes
# Standard-Rendering vollständig erhalten.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi
if ! printf '%s\n' "$input" | jq -e 'type == "object" and (.tasks | type == "array")' >/dev/null 2>&1; then
    exit 0
fi

# Ohne explizite Prozess-Metadaten keine GPT-Kapazitaet erfinden (wichtig fuer
# Attach an Supervisor-Worker, die das Dispatcher-Env nicht geerbt haben).
GPT_CONTEXT_WINDOW="${WHISPERM8_GPT56_CONTEXT_WINDOW:-0}"
case "$GPT_CONTEXT_WINDOW" in
    ''|*[!0-9]*) GPT_CONTEXT_WINDOW=0 ;;
esac
if [ "$GPT_CONTEXT_WINDOW" -le 0 ]; then GPT_CONTEXT_WINDOW=0; fi

# Pro aufgelöstem Task genau eine JSONL-Zeile ausgeben. Die Beschreibung wird
# gegen die nutzbare Zeilenbreite gekürzt; ANSI-Sequenzen zählen dabei nicht.
printf '%s\n' "$input" | jq -c --argjson gpt_context_window "$GPT_CONTEXT_WINDOW" '
    def sanitize_text:
        tostring
        | explode
        | map(if . == 10 then 32
              elif (. < 32 or (. >= 127 and . <= 159)) then empty
              else .
              end)
        | implode;
    def nonempty($value):
        (($value // "") | sanitize_text) as $text
        | if ($text | length) > 0 then $text else empty end;
    def rounded_k($value): (($value / 1000) | round | tostring) + "k";
    def shorten($text; $available):
        if $available <= 0 then ""
        elif ($text | length) <= $available then $text
        elif $available == 1 then "…"
        else $text[0:($available - 1)] + "…"
        end;

    (.columns // 120) as $raw_columns
    | (if ($raw_columns | type) == "number" and $raw_columns > 0
       then ($raw_columns | floor)
       else 120
       end) as $columns
    | .tasks[]
    | select(has("model") and (.model | type == "string") and (.model | length) > 0)
    | . as $task
    | (nonempty($task.name) // nonempty($task.label) // nonempty($task.id) // "subagent") as $name
    | ($task.model | sanitize_text) as $safe_model
    | select(($safe_model | length) > 0)
    | ($safe_model | sub("^claude-"; "")) as $short_model
    | (if ($safe_model | startswith("gpt-")) then "[36m" else "[35m" end) as $model_color
    # Claude Code meldet unbekannte Custom-Modelle teils als 200k. Nur die
    # explizit freigegebenen, gleich grossen GPT-Modelle erhalten die
    # konfigurierte Kapazitaet; alte/unknown GPT-IDs und echte native
    # Modellmetadaten (z. B. Opus 1M) bleiben unveraendert.
    | (($safe_model | ascii_downcase | test("^gpt-((5\\.6-(sol|terra|luna)|5\\.5|5\\.4)(-fast)?|5\\.4-mini)(\\[1m\\])?$"))) as $is_supported_gpt
    | (if ($is_supported_gpt and $gpt_context_window > 0 and $task.contextWindowSize == 200000)
       then $gpt_context_window
       else $task.contextWindowSize
       end) as $context_window_size
    | (if (($task.tokenCount | type) == "number" and ($context_window_size | type) == "number")
       then (rounded_k($task.tokenCount) + "/" + rounded_k($context_window_size))
       else ""
       end) as $tokens
    # Bei extrem schmalen Panels zuerst Tokens weglassen und danach Name sowie
    # Modell kürzen. So bleibt auch dann die gesamte sichtbare Zeile im Budget.
    | ($columns >= 3) as $use_brackets
    | shorten($short_model; ($columns - (if $use_brackets then 2 else 0 end))) as $display_model
    | ((if $use_brackets then "[" else "" end)
       + $display_model
       + (if $use_brackets then "]" else "" end)) as $model_plain
    | (if $tokens != "" and ($model_plain | length) + ($tokens | length) + 3 <= $columns
       then $tokens
       else ""
       end) as $display_tokens
    | (($columns - ($model_plain | length)
        - (if $display_tokens == "" then 0 else ($display_tokens | length) + 1 end))
       | if . > 1 then . - 1 else 0 end) as $name_width
    | shorten($name; $name_width) as $display_name
    | ($display_name
       + (if $display_name == "" then "" else " " end)
       + $model_plain
       + (if $display_tokens == "" then "" else " " + $display_tokens end)) as $plain_fixed
    | (($columns - ($plain_fixed | length) - 1) | if . > 0 then . else 0 end) as $description_width
    | shorten((($task.description // "") | sanitize_text); $description_width) as $description
    | ($display_name
       + (if $display_name == "" then "" else " " end)
       + (if $use_brackets then "[2m[[0m" else "" end)
       + $model_color + $display_model + "[0m"
       + (if $use_brackets then "[2m][0m" else "" end)
       + (if $description == "" then "" else " " + $description end)
       + (if $display_tokens == "" then "" else " [2m" + $display_tokens + "[0m" end)) as $content
    | {id: $task.id, content: $content}
'

exit 0
