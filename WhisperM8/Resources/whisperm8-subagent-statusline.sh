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

# Pro aufgelöstem Task genau eine JSONL-Zeile ausgeben. Die Beschreibung wird
# gegen die nutzbare Zeilenbreite gekürzt; ANSI-Sequenzen zählen dabei nicht.
# Laufende Tasks zeigen statt der unzuverlässigen Token-Metadaten ihre seit dem
# Start verstrichene Zeit. Claude Code ruft das Skript etwa alle fünf Sekunden auf.
printf '%s\n' "$input" | jq -c \
    --arg now_ms_override "${WHISPERM8_SUBAGENT_STATUSLINE_NOW_MS:-}" '
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
    def shorten($text; $available):
        if $available <= 0 then ""
        elif ($text | length) <= $available then $text
        elif $available == 1 then "…"
        else $text[0:($available - 1)] + "…"
        end;
    def two_digits($value):
        ($value | floor | tostring) as $text
        | if ($text | length) < 2 then "0" + $text else $text end;
    def elapsed_label($task; $now_ms):
        if (($task.status // "") == "running"
            and ($task.startTime | type) == "number"
            and $task.startTime > 0
            and $now_ms >= $task.startTime)
        then (($now_ms - $task.startTime) / 1000 | floor) as $seconds
            | if $seconds < 60 then ($seconds | tostring) + "s"
              elif $seconds < 3600
              then (($seconds / 60 | floor | tostring)
                    + "m " + two_digits($seconds % 60) + "s")
              else (($seconds / 3600 | floor | tostring)
                    + "h " + two_digits(($seconds % 3600) / 60) + "m")
              end
        else ""
        end;

    (try ($now_ms_override | tonumber) catch null) as $override_now_ms
    | (if ($override_now_ms | type) == "number" and $override_now_ms >= 0
       then ($override_now_ms | floor)
       else (now * 1000 | floor)
       end) as $now_ms
    | (.columns // 120) as $raw_columns
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
    | elapsed_label($task; $now_ms) as $elapsed
    # Bei extrem schmalen Panels zuerst die Laufzeit weglassen und danach Name
    # sowie Modell kürzen. Das Modell bleibt gegenüber der Beschreibung priorisiert.
    | ($columns >= 3) as $use_brackets
    | shorten($short_model; ($columns - (if $use_brackets then 2 else 0 end))) as $display_model
    | ((if $use_brackets then "[" else "" end)
       + $display_model
       + (if $use_brackets then "]" else "" end)) as $model_plain
    | (if $elapsed != "" and ($model_plain | length) + ($elapsed | length) + 3 <= $columns
       then $elapsed
       else ""
       end) as $display_elapsed
    | (($columns - ($model_plain | length)
        - (if $display_elapsed == "" then 0 else ($display_elapsed | length) + 1 end))
       | if . > 1 then . - 1 else 0 end) as $name_width
    | shorten($name; $name_width) as $display_name
    | ($display_name
       + (if $display_name == "" then "" else " " end)
       + $model_plain) as $left_fixed_plain
    | (($columns - ($left_fixed_plain | length)
        - (if $display_elapsed == "" then 0 else ($display_elapsed | length) + 1 end)
        - 1)
       | if . > 0 then . else 0 end) as $description_width
    | shorten((($task.description // "") | sanitize_text); $description_width) as $description
    | ($left_fixed_plain
       + (if $description == "" then "" else " " + $description end)) as $left_plain
    | (if $display_elapsed == "" then 0
       else (($columns - ($left_plain | length) - ($display_elapsed | length))
             | if . > 0 then . else 1 end)
       end) as $elapsed_gap
    | ($display_name
       + (if $display_name == "" then "" else " " end)
       + (if $use_brackets then "[2m[[0m" else "" end)
       + $model_color + $display_model + "[0m"
       + (if $use_brackets then "[2m][0m" else "" end)
       + (if $description == "" then "" else " " + $description end)
       + (if $display_elapsed == "" then ""
          else (" " * $elapsed_gap) + "[2m" + $display_elapsed + "[0m"
          end)) as $content
    | {id: $task.id, content: $content}
'

exit 0
