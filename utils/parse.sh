#!/usr/bin/env bash
set -euo pipefail

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

# 1) Slurp stdin if piped
if ! [ -t 0 ]; then
  cat - >>"$TEMP_FILE"
fi

# 2) Slurp args (files or literals)
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    if [ -f "$arg" ]; then
      cat "$arg" >>"$TEMP_FILE"
    else
      echo "$arg" >>"$TEMP_FILE"
    fi
  done
fi

# 3) If still empty and interactive, read stdin
if [ ! -s "$TEMP_FILE" ] && [ -t 0 ]; then
  cat - >>"$TEMP_FILE"
fi

# 4) Process the file with awk, matching fences by regex
awk '
  BEGIN { in_block = 0 }

  # start of a ```
  $0 ~ /^```qrx[[:space:]]*$/ {
    in_block = 1
    next
  }

  # end of any ```
  $0 ~ /^```[[:space:]]*$/ {
    in_block = 0
    next
  }

  # inside a qrx block: execute the line
  in_block == 1 {
    system($0)
    next
  }

  # otherwise: print the line verbatim
  {
    print
  }
' "$TEMP_FILE"
