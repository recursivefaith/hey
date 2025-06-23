#!/bin/bash

PROMPT_TO_SEND=""
if [[ -n "$1" ]]; then
    PROMPT_TO_SEND="$1"
else
  PROMPT_TO_SEND="$(cat $HEY/prompts/gnosiscopilot.md)"
fi

PIPED_INPUT=""
if ! [ -t 0 ]; then # Check if stdin is not a terminal (i.e., it's a pipe or file redirection)
    PIPED_INPUT=$(cat)
fi

if [[ -n "$PIPED_INPUT" ]]; then
    # If piped input exists, echo it first, then run context for file-based contexts
    # The parentheses ensure both commands' output are combined into a single pipe
    (echo "<context type=\"piped\">$PIPED_INPUT</context>"; context "$ME/context/epiphany/"* "$HEY/hey.sh.qrx" "$HISTORY") | hey "$PROMPT_TO_SEND" --markdown --chat
else
    # If no piped input, just use file-based contexts
    context "$ME/context/epiphany/"* "$HEY/hey.sh.qrx" "$HISTORY" | hey "$PROMPT_TO_SEND" --markdown --chat
fi
