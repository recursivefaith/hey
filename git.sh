#!/bin/bash

# git.sh: A Bash script to assist with crafting and executing Git commit messages by leveraging the hey.sh script.

# --- Configuration & Variables ---
HEY_COMMAND="${HEY:-}/hey.sh" # Path to your hey.sh script
HISTORY_FILE="${HISTORY:-}" # Required environment variable
CHANGELOG_FILE="${CHANGELOG:-}" # Required environment variable
DEBUG_MODE=false
SHOW_HELP=false
MESSAGE_PREFIX=""
GIT_DIFF_OUTPUT=""
DEVLOG_CONTENT=""
PROPOSED_COMMIT_MESSAGE="" # Stores the AI-generated message

# --- Functions ---

# Displays help message
show_help() {
  cat << EOF
Usage: $0 [options] [optional_message_prefix]

A script to generate Git commit messages using '$HEY_COMMAND' and manage commit history.

Options:
  [optional_message_prefix]  A string to prefix the AI-generated commit summary.
  --debug                    Enable debug logging for git.sh and '$HEY_COMMAND'.
  -h, --help                 Display this help message.

Environment Variables:
  HISTORY     (Required) Your commit history log file path.
  CHANGELOG   (Required) Your changelog log file path.
  GEMINI_API_KEY (Required by $HEY_COMMAND) Your Google Gemini API key.
  GEMINI_MODEL   (Optional, for $HEY_COMMAND) Default Gemini model to use.
EOF
}

# Logs messages if DEBUG_MODE is true
debug_log() {
  if [ "$DEBUG_MODE" = true ]; then
    echo "DEBUG: $1" >&2
  fi
}

# Checks if the current directory is a Git repository
is_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Gathers git diff output by temporarily staging all changes
# (including untracked files) to provide comprehensive context to the AI.
# The staging area is reset afterwards to preserve user's original state.
get_git_diff() {
  debug_log "Attempting to get git diff for context..."
  if ! is_git_repo; then
    echo "Error: Not a Git repository." >&2
    return 1
  fi

  # Check if there are any changes (staged, unstaged, or untracked that could be added)
  # This grep pattern covers M, A, D, R, C, U (staged, unstaged, and untracked)
  if ! git status --porcelain | grep -qE '^[MARCUD ]|^\?\?'; then
    echo "Error: No pending changes (staged, unstaged, or untracked) detected to summarize." >&2
    echo "       Run 'git status' to see current state." >&2
    return 1
  fi

  debug_log "Temporarily staging all changes with 'git add .' to capture comprehensive diff for AI..."
  git add .
  local add_exit_code=$?
  if [ $add_exit_code -ne 0 ]; then
    echo "Error: 'git add .' failed during diff collection (exit code $add_exit_code). Cannot proceed." >&2
    # Attempt to reset in case it partially staged
    git reset >/dev/null 2>&1 || true
    return 1
  fi
  
  # Capture the diff of all now-staged changes
  GIT_DIFF_OUTPUT=$(git diff --staged)
  local diff_exit_code=$?

  debug_log "Resetting staged changes back to original state with 'git reset'..."
  # Use --quiet to suppress output on success, '|| true' to prevent script exit on reset failure
  git reset --quiet || { echo "Warning: 'git reset' failed after diff collection. Your changes might remain staged." >&2; }

  if [ $diff_exit_code -ne 0 ]; then
    echo "Error: Failed to collect staged diff after 'git add .' (exit code $diff_exit_code)." >&2
    return 1
  fi

  if [ -z "$GIT_DIFF_OUTPUT" ]; then
      echo "Error: Could not retrieve meaningful git diff output after temporary staging." >&2
      # This can happen if 'git add .' was performed but the resulting staged state
      # yields no meaningful diff (e.g., adding an empty file, or only whitespace changes).
      # The initial 'git status' check should prevent most cases of no changes.
      return 1
  fi

  debug_log "Final git diff output captured. Length: ${#GIT_DIFF_OUTPUT} bytes."
  return 0
}

# Reads the content of the history file
read_history_file() {
  debug_log "Reading history file: $HISTORY_FILE"
  if [ -f "$HISTORY_FILE" ]; then
    DEVLOG_CONTENT=$(cat "$HISTORY_FILE")
    debug_log "History file read. Size: ${#DEVLOG_CONTENT} bytes."
  else
    debug_log "History file '$HISTORY_FILE' not found or empty. Treating as empty."
    DEVLOG_CONTENT=""
  fi
}

# Generates commit message using hey-gemini.sh
generate_summary_with_hey() {
  local hey_debug_flag=""
  if [ "$DEBUG_MODE" = true ]; then
    hey_debug_flag="--debug"
    debug_log "Passing --debug flag to $HEY_COMMAND."
  fi

  local hey_input_devlog=""
  if [ -n "$DEVLOG_CONTENT" ]; then
    hey_input_devlog="<devlog>${DEVLOG_CONTENT}</devlog>"
  fi
  local hey_input_changes="<changes>${GIT_DIFF_OUTPUT}</changes>"

  # Construct the full piped input for 'hey-gemini.sh'
  local hey_full_input=""
  if [ -n "$hey_input_devlog" ] && [ -n "$hey_input_changes" ]; then
    hey_full_input="${hey_input_devlog}\n${hey_input_changes}"
  elif [ -n "$hey_input_devlog" ]; then
    hey_full_input="${hey_input_devlog}"
  elif [ -n "$hey_input_changes" ]; then
    hey_full_input="${hey_input_changes}"
  fi

  # The prompt itself is passed as a command-line argument to hey-gemini.sh
  local hey_prompt="$(cat $HEY/prompts/git.md)"

  debug_log "Constructed hey input for pipe (will be wrapped as context by hey):"
  debug_log "$hey_full_input"
  debug_log "Constructed hey prompt (will be wrapped as prompt by hey): '$hey_prompt'"
  
  PROPOSED_COMMIT_MESSAGE=$(echo -e "$hey_full_input" | "$HEY_COMMAND" $hey_debug_flag "$hey_prompt")
  local hey_exit_code=$?

  if [ $hey_exit_code -ne 0 ]; then
    echo "Error: '$HEY_COMMAND' failed with exit code $hey_exit_code." >&2
    # If hey-gemini.sh printed error to its stdout, it will be in PROPOSED_COMMIT_MESSAGE
    if [ -n "$PROPOSED_COMMIT_MESSAGE" ]; then 
      echo "Hey output (potential error message):" >&2
      echo "$PROPOSED_COMMIT_MESSAGE" >&2
    fi
    return 1
  fi

  if [ -z "$PROPOSED_COMMIT_MESSAGE" ]; then
    echo "Warning: '$HEY_COMMAND' returned an empty message." >&2
  fi

  debug_log "Generated commit message (raw):"
  debug_log "$PROPOSED_COMMIT_MESSAGE"
  return 0
}

# Prompts user for action (Accept, Regenerate, Cancel)
prompt_user_action() {
  while true; do
    echo ""
    echo "-------------------------------------"
    echo "Proposed commit message:"
    if [ -n "$MESSAGE_PREFIX" ]; then
      echo "$MESSAGE_PREFIX"
      # Add a newline for visual separation in prompt if prefix doesn't end with one
      if [[ "$MESSAGE_PREFIX" != *$'\n'* ]] && [ -n "$PROPOSED_COMMIT_MESSAGE" ]; then
          echo "" 
      fi
    fi
    echo "$PROPOSED_COMMIT_MESSAGE"
    echo "-------------------------------------"
    read -rp "(A)ccept, (R)egenerate, (C)ancel? [A] " choice
    
    # If choice is empty, default to 'a' (Accept)
    choice="${choice:-a}"
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

    case "$choice" in
      a) return 0 ;; # Accept
      r) 
        echo "Regenerating commit message..."
        if ! generate_summary_with_hey; then
          echo "Error regenerating message. Please check the '$HEY_COMMAND' script or API key." >&2
          # Continue the loop to prompt again after error, allowing user to retry or cancel.
          continue 
        fi
        ;; # Regenerate, loop again
      c) return 1 ;; # Cancel
      *) echo "Invalid choice. Please enter A, R, or C." >&2 ;;
    esac
  done
}

# Performs git commit and push actions
perform_commit_and_push_actions() {
  local current_time=$(date +%H%M)
  local repo_name=""
  local primary_remote="recursivefaith"

  debug_log "Preparing commit and push actions..."
  if is_git_repo; then
    # Use `git rev-parse --show-toplevel` to get the root directory
    # of the current repository (works correctly for main repos and submodules),
    # then use `basename` to extract its name.
    repo_name=$(basename "$(git rev-parse --show-toplevel)")
    debug_log "Using repository name from current git context: $repo_name"
  else
    echo "Error: Not a Git repository, cannot perform commit/push." >&2
    return 1
  fi
  
  local repo_identifier="${primary_remote}/${repo_name}"
  
  local final_commit_message=""
  if [ -n "$MESSAGE_PREFIX" ]; then
    final_commit_message="${MESSAGE_PREFIX}"
    # Ensure there are two newlines between the prefix and the AI-generated message
    # for conventional Git commit message formatting (subject\n\nbody).
    # Only add if the prefix doesn't already contain multiple newlines.
    if [[ "$final_commit_message" != *$'\n\n'* ]] && [ -n "$PROPOSED_COMMIT_MESSAGE" ]; then
        final_commit_message+="\n\n"
    elif [[ "$final_commit_message" != *$'\n'* ]] && [ -n "$PROPOSED_COMMIT_MESSAGE" ]; then
        final_commit_message+="\n\n" # Ensure at least two newlines
    fi
  fi
  final_commit_message+="$PROPOSED_COMMIT_MESSAGE"

  debug_log "Final commit message: '$final_commit_message'"

  # Append to history file BEFORE staging and committing
  # Replace newlines in the message for a single line in the history entry.
  # Use space as replacement for better readability in simple log file.
  local history_entry_message_sanitized=$(echo "$final_commit_message" | tr '\n' ' ' | sed 's/  */ /g')
  local history_entry="**${current_time}** \`<${repo_identifier}.git>\` ${history_entry_message_sanitized}"
  
  # --- Start of user requested insertion logic (using awk) ---
  # Awk script to find the "---" line immediately followed by a "#" heading,
  # and insert the new entry BEFORE the "---" line.
  # If no such marker sequence is found, the entry is appended to the end of the file.
  local awk_script='
BEGIN {
    new_entry = ARGV[1];
    delete ARGV[1];
    found_marker_sequence = 0
    insert_at_line_num = 0 # This will be the line number *before* which to insert
    line_count = 0
    prev_line_was_dashes = 0 # Flag to check if previous line was "---"
}

{
    line_count++;
    lines[line_count] = $0

    # Check if the current line is a heading AND the previous line was "---"
    if (prev_line_was_dashes == 1 && $0 ~ /^[[:space:]]*#[[:graph:]]/) {
        # The marker sequence is found: "---" (at line_count - 1) followed by heading (at line_count)
        # We want to insert *before* the "---" line, so insert_at_line_num should be (line_count - 1)
        insert_at_line_num = line_count - 1
        found_marker_sequence = 1
        prev_line_was_dashes = 0 # Reset flag once sequence found
    } else if ($0 ~ /^[[:space:]]*---[[:space:]]*$/) {
        # Current line is "---", set flag for next iteration
        prev_line_was_dashes = 1
    } else {
        # Neither a heading after "---" nor a "---" itself, reset flag
        prev_line_was_dashes = 0
    }
}

END {
    if (found_marker_sequence) {
        for (i = 1; i <= line_count; i++) {
            if (i == insert_at_line_num) {
                print new_entry # Insert the new entry BEFORE the target line
            }
            print lines[i]
        }
    } else {
        # If no marker sequence found, append to the end of the file.
        for (i = 1; i <= line_count; i++) {
            print lines[i]
        }
        print new_entry
    }
}
'

  debug_log "Attempting to insert history entry: '$history_entry' into '$HISTORY_FILE' using awk."
  # Use awk with temporary files for cross-platform compatibility for in-place editing.
  awk "$awk_script" "$history_entry" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
  if [ $? -ne 0 ]; then
    echo "Error: Awk failed for history file '$HISTORY_FILE'. Check file content/format or permissions." >&2
    rm -f "${HISTORY_FILE}.tmp" # Clean up temporary file
    return 1
  fi
  mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE" || { echo "Error: Failed to move temporary history file. Permissions issue?" >&2; return 1; }
  debug_log "History entry successfully inserted into '$HISTORY_FILE'."

  debug_log "Attempting to insert history entry: '$history_entry' into '$CHANGELOG_FILE' using awk."
  awk "$awk_script" "$history_entry" "$CHANGELOG_FILE" > "${CHANGELOG_FILE}.tmp"
  if [ $? -ne 0 ]; then
    echo "Error: Awk failed for changelog file '$CHANGELOG_FILE'. Check file content/format or permissions." >&2
    rm -f "${CHANGELOG_FILE}.tmp" # Clean up temporary file
    return 1
  fi
  mv "${CHANGELOG_FILE}.tmp" "$CHANGELOG_FILE" || { echo "Error: Failed to move temporary changelog file. Permissions issue?" >&2; return 1; }
  debug_log "History entry successfully inserted into '$CHANGELOG_FILE'."
  # --- End of user requested insertion logic ---

  # Stage changes (including the updated history file)
  echo ""
  echo "Staging all changes with 'git add .'"
  git add .
  if [ $? -ne 0 ]; then
    echo "Error: 'git add .' failed. Commit and push aborted." >&2
    return 1
  fi

  # Execute commit
  echo ""
  echo "Executing commit..."
  git commit -m "$final_commit_message"
  if [ $? -ne 0 ]; then
    echo "Error: 'git commit' failed. Push aborted." >&2
    echo "       (Note: The message has been appended to history regardless, and history file staged if successful.)" >&2
    return 1
  fi
  echo "Commit successful."

  # Push to remotes
  echo ""
  local remotes=$(git remote)
  if [ -z "$remotes" ]; then
    echo "No remotes configured to push to."
  else
    echo "Attempting to push to all remotes..."
    local push_failed_remotes=""
    for remote in $remotes; do
      echo ""
      echo "Pushing to remote: $remote"
      git push "$remote"
      if [ $? -ne 0 ]; then
        echo "Warning: 'git push $remote' failed." >&2
        push_failed_remotes+=" $remote"
      fi
    done
    if [ -z "$push_failed_remotes" ]; then
      echo "Push attempted to all remotes and all succeeded."
    else
      echo "Push attempted to all remotes, but the following failed:$(echo "$push_failed_remotes" | xargs)" >&2
      echo "Check your remote configurations and try 'git push' manually for those." >&2
    fi
  fi

  echo ""
  echo "Commit successful. Push attempted to all remotes. Details appended to history."
  return 0
}

# --- Main Script Logic ---

# Parse command-line options using `getopt` for robust parsing
PARSED_ARGS=$(getopt -o h --long debug,help -- "$@")
if [ $? -ne 0 ]; then
    echo "Error: Failed to parse options." >&2
    show_help
    exit 1
fi
eval set -- "$PARSED_ARGS"

ARGS_AFTER_OPTIONS=() # Array to hold positional arguments
while true; do
  case "$1" in
    --debug)
      DEBUG_MODE=true
      shift
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    --) # End of options
      shift
      break
      ;;
    *) # Positional arguments
      ARGS_AFTER_OPTIONS+=("$1")
      shift
      ;;
  esac
done

# Handle help request first
if [ "$SHOW_HELP" = true ]; then
  show_help
  exit 0
fi

# Set positional argument as message prefix
if [ ${#ARGS_AFTER_OPTIONS[@]} -gt 0 ]; then
    MESSAGE_PREFIX="${ARGS_AFTER_OPTIONS[*]}"
    debug_log "Message prefix set: '$MESSAGE_PREFIX'"
fi

# Validate HISTORY environment variable
if [ -z "$HISTORY_FILE" ]; then
  echo "Error: HISTORY environment variable is not set. Please set it to your commit history log file." >&2
  show_help
  exit 1
fi

# Validate CHANGELOG environment variable
if [ -z "$CHANGELOG_FILE" ]; then
  echo "Error: CHANGELOG environment variable is not set. Please set it to your changelog file." >&2
  show_help
  exit 1
fi

# Pre-checks for required commands
if ! command -v "$HEY_COMMAND" &>/dev/null; then
    echo "Error: '$HEY_COMMAND' command not found. Please ensure it's in your PATH." >&2
    exit 1
fi
if ! command -v git &>/dev/null; then
    echo "Error: 'git' command not found. Please ensure it's in your PATH." >&2
    exit 1
fi
# `hey-gemini.sh` uses `jq` internally, so `git.sh` should check for it too.
if ! command -v jq &>/dev/null; then 
    echo "Error: 'jq' command not found. Please ensure it's in your PATH." >&2
    echo "       The '$HEY_COMMAND' script requires 'jq' for JSON processing." >&2
    exit 1
fi
# `awk` is now used for in-place editing logic.
if ! command -v awk &>/dev/null; then
    echo "Error: 'awk' command not found. Please ensure it's in your PATH." >&2
    echo "       The 'git.sh' script requires 'awk' for modifying history/changelog files." >&2
    exit 1
fi


# Gather necessary input (history log and git diff)
read_history_file
if ! get_git_diff; then
  exit 1 # get_git_diff prints its own error message
fi

# Generate the initial commit message using hey-gemini.sh
if ! generate_summary_with_hey; then
  exit 1 # generate_summary_with_hey prints its own error message
fi

# Prompt user for action (Accept, Regenerate, Cancel)
if ! prompt_user_action; then
  echo "Commit message generation cancelled. No commit or push performed."
  exit 0
fi

# Perform commit and push actions if accepted
if ! perform_commit_and_push_actions; then
  exit 1
fi

exit 0

