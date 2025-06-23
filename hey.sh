#!/bin/bash

# hey-gemini.sh: A minimalist Bash agent for Google's Gemini API.

# --- Color Definitions ---
# Foreground
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'       # For debug
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'         # For info messages
COLOR_BRIGHT_GREEN='\033[0;92m' # For "Gemini:" prompt label
COLOR_BRIGHT_BLUE='\033[0;94m'  # For "You:" prompt label
COLOR_RESET='\033[0m'           # Reset color

# --- Configuration ---
DEFAULT_GEMINI_MODEL="gemini-2.5-flash-preview-05-20"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
GEMINI_MODEL_ENV="${GEMINI_MODEL:-}"

# --- Script Variables ---
EFFECTIVE_GEMINI_MODEL=""
PROMPT_STRING=""
PIPED_INPUT="" # Stores raw piped input
CHAT_MODE=false
STREAM_MODE=false
DEBUG_MODE=false
SHOW_HELP=false
MODEL_OVERRIDE=""
MARKDOWN_MODE=false 
CHAT_HISTORY_JSON="[]" 
LAST_SAVE_FILENAME="" 

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHATS_DIR="${SCRIPT_DIR}/chats"
MARKDOWN_SCRIPT_PATH="${SCRIPT_DIR}/utils/markdown.mjs"


# --- Functions ---

show_help() {
cat << EOF
hey-gemini.sh: A minimalist Bash agent for Google's Gemini API.

Syntax: hey-gemini.sh [options] [prompt_string]
  cat input.txt | hey-gemini.sh [options] [optional_prompt_string_appended_to_pipe]

Options:
  [prompt_string]   The main prompt text.
  --chat            Enable a looping chat session. Type /q to quit.
                    Type /s [filename] or /save [filename] to save chat to './chats/' directory.
  --model 'modelname' Override the default/environment Gemini model.
  --stream          Use the streaming API endpoint.
  --markdown        Pipe Gemini's output to './utils/markdown.mjs' for formatting.
  --debug           Print debug information (curl command, payload, raw response).
  -h, --help        Display this help message.

Environment Variables:
  GEMINI_API_KEY    (Required) Your Google Gemini API key.
  GEMINI_MODEL      (Optional) Default Gemini model to use if --model is not set.
                    Defaults to '$DEFAULT_GEMINI_MODEL' if neither is specified.
EOF
}

debug_log() {
  if [ "$DEBUG_MODE" = true ]; then
    printf "%b" "${COLOR_YELLOW}DEBUG: $1${COLOR_RESET}\n" >&2
  fi
}

error_exit() {
  printf "%b" "${COLOR_RED}ERROR: $1${COLOR_RESET}\n" >&2
  exit 1
}

set_effective_model() {
  if [ -n "$MODEL_OVERRIDE" ]; then
    EFFECTIVE_GEMINI_MODEL="$MODEL_OVERRIDE"
    debug_log "Using model from --model option: $EFFECTIVE_GEMINI_MODEL"
  elif [ -n "$GEMINI_MODEL_ENV" ]; then
    EFFECTIVE_GEMINI_MODEL="$GEMINI_MODEL_ENV"
    debug_log "Using model from GEMINI_MODEL env var: $EFFECTIVE_GEMINI_MODEL"
  else
    EFFECTIVE_GEMINI_MODEL="$DEFAULT_GEMINI_MODEL"
    debug_log "Using default model: $EFFECTIVE_GEMINI_MODEL"
  fi
}

read_piped_input() {
  if [ ! -t 0 ]; then 
    PIPED_INPUT=$(cat -) 
    debug_log "Read piped input."
  fi
}

build_input_string() {
  local combined_input_for_api=""
  if [ -n "$PIPED_INPUT" ]; then 
    combined_input_for_api="<context>${PIPED_INPUT}</context>"
  fi
  if [ -n "$PROMPT_STRING" ]; then
    if [ -n "$combined_input_for_api" ]; then
      combined_input_for_api="${combined_input_for_api}\n<prompt>${PROMPT_STRING}</prompt>"
    else
      combined_input_for_api="<prompt>${PROMPT_STRING}</prompt>"
    fi
  fi
  echo "$combined_input_for_api"
}

build_payload() {
  local input_text_for_api="$1" 
  local current_user_message_json 
  
  current_user_message_json=$(jq -n --arg role "user" --rawfile text /dev/stdin '{role: $role, parts: [{text: $text}]}' <<< "$input_text_for_api")
  local jq_status_curr_msg=$? 

  if [ "${jq_status_curr_msg:-1}" -ne 0 ] || [ -z "$current_user_message_json" ]; then 
    debug_log "jq failed to create current_user_message_json (status: ${jq_status_curr_msg:-1}) or it was empty. input_text_for_api was: $(head -c 100 <<< "$input_text_for_api")..."
    return 1
  fi

  local final_payload_json
  if [ "$CHAT_MODE" = true ]; then
    local combined_array_str
    local temp_jq_input_bp; temp_jq_input_bp=$(mktemp)

    printf "%s\n" "$CHAT_HISTORY_JSON" > "$temp_jq_input_bp"
    printf "%s\n" "$current_user_message_json" >> "$temp_jq_input_bp"

    combined_array_str=$(jq -s '.[0] + [.[1]]' < "$temp_jq_input_bp")
    local jq_status_combine=$?
    rm -f "$temp_jq_input_bp"
    
    if [ "${jq_status_combine:-1}" -ne 0 ] || [ -z "$combined_array_str" ]; then 
        debug_log "jq pipeline (stage 1: history + current_msg) failed (status: ${jq_status_combine:-1}). CHAT_HISTORY_JSON: $(head -c 100 <<< "$CHAT_HISTORY_JSON")... current_user_message_json: $(head -c 100 <<< "$current_user_message_json")..."
        return 1
    fi

    final_payload_json=$(jq '{contents: .}' <<< "$combined_array_str")
    local jq_status_wrap=$?
    if [ "${jq_status_wrap:-1}" -ne 0 ] || [ -z "$final_payload_json" ]; then 
        debug_log "jq pipeline (stage 2: wrapping contents) failed (status: ${jq_status_wrap:-1}). combined_array_str: $(head -c 100 <<< "$combined_array_str")..."
        return 1
    fi
  else 
    final_payload_json=$(jq '{contents: [.]}' <<< "$current_user_message_json")
    local jq_status_non_chat=$?
     if [ "${jq_status_non_chat:-1}" -ne 0 ] || [ -z "$final_payload_json" ]; then 
        debug_log "jq (non-chat payload construction) failed (status: ${jq_status_non_chat:-1}). current_user_message_json: $(head -c 100 <<< "$current_user_message_json")..."
        return 1
    fi
  fi
  
  echo "$final_payload_json"
  return 0
}


send_standard_request() {
  local payload="$1"
  local api_url="https://generativelanguage.googleapis.com/v1beta/models/${EFFECTIVE_GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}"

  debug_log "Standard API URL: $api_url"
  if [ "$DEBUG_MODE" = true ]; then
      printf "%b" "${COLOR_YELLOW}DEBUG: Curl command (standard): curl -s -X POST -H 'Content-Type: application/json' -d @- '$api_url'${COLOR_RESET}\n" >&2
      printf "%b" "${COLOR_YELLOW}DEBUG: Request Payload (standard):${COLOR_RESET}\n" >&2
      jq '.' <<< "$payload" >&2 
  fi

  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d @- \
    "$api_url" <<< "$payload") 
  local curl_exit_code=$? 

  if [ "$DEBUG_MODE" = true ]; then
    printf "%b" "${COLOR_YELLOW}DEBUG: Raw API Response (standard):${COLOR_RESET}\n" >&2
    echo "$response" | jq '.' >&2 
  fi

  if [ "${curl_exit_code:-1}" -ne 0 ]; then  
    printf "%b" "${COLOR_RED}Error: curl command failed with exit code ${curl_exit_code:-1}.${COLOR_RESET}\n" >&2
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        printf "%b" "${COLOR_RED}API Error (from curl response):${COLOR_RESET}\n" >&2
        echo "$response" | jq '.error' >&2
    fi
    return 1
  fi

  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    printf "%b" "${COLOR_RED}Error: API returned an error.${COLOR_RESET}\n" >&2
    echo "$response" | jq '.error' >&2
    return 1
  fi

  local text_output
  text_output=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // ""')
  
  if [ -z "$text_output" ] && ! echo "$response" | jq -e '.candidates[0].content.parts[0].text' > /dev/null 2>&1 ; then
      debug_log "Could not extract text from standard response. Path .candidates[0].content.parts[0].text might be missing or null."
  fi
  
  echo "$text_output" 
  return 0 
}

handle_stream_request() {
  local payload="$1"
  local api_url="https://generativelanguage.googleapis.com/v1beta/models/${EFFECTIVE_GEMINI_MODEL}:streamGenerateContent?alt=sse&key=${GEMINI_API_KEY}"

  debug_log "Streaming API URL: $api_url"
  if [ "$DEBUG_MODE" = true ]; then
      printf "%b" "${COLOR_YELLOW}DEBUG: Curl command (streaming): curl --no-buffer -s -X POST -H 'Content-Type: application/json' -d @- '$api_url'${COLOR_RESET}\n" >&2
      printf "%b" "${COLOR_YELLOW}DEBUG: Request Payload (streaming):${COLOR_RESET}\n" >&2
      jq '.' <<< "$payload" >&2 
  fi

  local full_streamed_response=""
  local stream_had_api_error=0
  local output_processed=false
  local tmp_curl_exit_code_file
  tmp_curl_exit_code_file=$(mktemp) 

  local can_write_to_tty=true
  if ! (printf "" > /dev/tty 2>/dev/null) ; then
    can_write_to_tty=false
    debug_log "/dev/tty not writable, live stream chunks will not be printed to terminal."
  fi

  while IFS= read -r line; do
    output_processed=true 
    if [[ "$line" == "data: "* ]]; then
      local json_data="${line#data: }"
      if [ "$DEBUG_MODE" = true ]; then
        printf "%b" "${COLOR_YELLOW}DEBUG: Raw Stream Chunk (JSON):${COLOR_RESET}\n" >&2
        echo "$json_data" | jq '.' >&2
      fi
      local chunk_text 
      chunk_text=$(echo "$json_data" | jq -r '.candidates[0].content.parts[0].text // ""')
      
      if [ "$can_write_to_tty" = true ]; then
        if [ "$CHAT_MODE" = false ] || ([ "$CHAT_MODE" = true ] && [ "$MARKDOWN_MODE" = false ]); then
            printf "%b" "${COLOR_GREEN}${chunk_text}${COLOR_RESET}" > /dev/tty
        fi
      fi
      full_streamed_response+="$chunk_text"

      if echo "$json_data" | jq -e '.error' > /dev/null 2>&1; then
        (printf "%b" "\n${COLOR_RED}Error: API returned an error in stream.${COLOR_RESET}\n" >&2)
        (echo "$json_data" | jq '.error' >&2)
        stream_had_api_error=1 
      fi
    elif [[ -n "$line" ]]; then 
      debug_log "Stream Non-data line: $line"
    fi
  done < <(curl --no-buffer -s -X POST \
    -H "Content-Type: application/json" \
    -d @- \
    "$api_url" <<< "$payload"; echo $? > "$tmp_curl_exit_code_file") 

  local curl_rc_from_file 
  curl_rc_from_file=$(cat "$tmp_curl_exit_code_file")
  rm -f "$tmp_curl_exit_code_file"

  if [ "${curl_rc_from_file:-1}" -ne 0 ]; then 
      debug_log "Curl in stream failed with exit code: ${curl_rc_from_file:-1}"
      echo "$full_streamed_response" 
      return 1 
  fi
  
  if [ "$stream_had_api_error" -ne 0 ]; then
      echo "$full_streamed_response" 
      return 1 
  fi

  if [ "$output_processed" = false ] && [ "${curl_rc_from_file:-1}" -eq 0 ]; then
      debug_log "Stream ended: curl succeeded but no SSE data lines were processed."
  fi
  
  echo "$full_streamed_response" 
  return 0 
}

save_chat_to_file() {
    local filename_to_save_full_path="$1" 
    local formatted_chat_content="" 

    if [ -n "$PIPED_INPUT" ]; then
        formatted_chat_content+="<context>${PIPED_INPUT}</context>\n"
    fi

    local num_entries 
    num_entries=$(jq 'length' <<< "$CHAT_HISTORY_JSON")
    local jq_len_status=$?
    if [ "${jq_len_status:-1}" -ne 0 ]; then 
        debug_log "jq failed to get length of chat history for saving. Status: ${jq_len_status:-1}"
        num_entries=0 
    fi

    for (( i=0; i<num_entries; i++ )); do
        local role text 
        role=$(jq -r ".[$i].role" <<< "$CHAT_HISTORY_JSON")
        local ps_role_jq=$?
        text=$(jq -r ".[$i].parts[0].text" <<< "$CHAT_HISTORY_JSON")
        local ps_text_jq=$?

        if [ "${ps_role_jq:-1}" -ne 0 ] || [ "${ps_text_jq:-1}" -ne 0 ]; then 
            debug_log "jq failed to extract role/text for history item $i during save. Role status: ${ps_role_jq:-1}, Text status: ${ps_text_jq:-1}"
            continue 
        fi

        if [ "$role" == "user" ]; then
            formatted_chat_content+="<user ${USER}>${text}</user>\n"
        elif [ "$role" == "model" ]; then
            formatted_chat_content+="<copilot ${EFFECTIVE_GEMINI_MODEL}>${text}</copilot>\n"
        fi
    done

    if ! mkdir -p "$(dirname "$filename_to_save_full_path")"; then
        printf "%b" "${COLOR_RED}Error: Could not create directory $(dirname "$filename_to_save_full_path") for chat log.${COLOR_RESET}\n" > /dev/tty
        return 1
    fi
    
    printf "%s" "$formatted_chat_content" > "$filename_to_save_full_path"
    if [ $? -eq 0 ]; then
        return 0 
    else
        printf "%b" "${COLOR_RED}Error: Failed to save chat to ${filename_to_save_full_path}.${COLOR_RESET}\n" > /dev/tty
        return 1 
    fi
}

# --- Argument Parsing ---
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat) CHAT_MODE=true; shift ;;
    --stream) STREAM_MODE=true; shift ;;
    --debug) DEBUG_MODE=true; shift ;;
    --markdown) MARKDOWN_MODE=true; shift ;; 
    --model)
      if [[ -n "$2" ]]; then MODEL_OVERRIDE="$2"; shift 2;
      else error_exit "--model option requires an argument."; fi ;;
    -h|--help) SHOW_HELP=true; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ ${#ARGS[@]} -gt 0 ]; then
    PROMPT_STRING="${ARGS[*]}"
fi

# --- Main Logic ---

if [ "$SHOW_HELP" = true ]; then
  show_help
  exit 0
fi

if [ -z "$GEMINI_API_KEY" ]; then
  printf "%b" "${COLOR_RED}Error: GEMINI_API_KEY environment variable is not set.${COLOR_RESET}\n" >&2
  show_help
  exit 1
fi

if [ "$MARKDOWN_MODE" = true ]; then
    if [ ! -f "$MARKDOWN_SCRIPT_PATH" ]; then
        printf "%b" "${COLOR_RED}Error: Markdown script not found at ${MARKDOWN_SCRIPT_PATH}${COLOR_RESET}\n" >&2
        printf "%b" "${COLOR_YELLOW}Disabling markdown mode for this run.${COLOR_RESET}\n" >&2
        MARKDOWN_MODE=false 
    elif [ ! -x "$MARKDOWN_SCRIPT_PATH" ]; then
        printf "%b" "${COLOR_RED}Error: Markdown script at ${MARKDOWN_SCRIPT_PATH} is not executable.${COLOR_RESET}\n" >&2
        printf "%b" "${COLOR_YELLOW}Disabling markdown mode for this run.${COLOR_RESET}\n" >&2
        MARKDOWN_MODE=false
    fi
fi

read_piped_input 
set_effective_model

if [ "$CHAT_MODE" = true ]; then
  printf "%b" "${COLOR_CYAN}Starting chat session with ${EFFECTIVE_GEMINI_MODEL}. Type '/q' to quit, '/s [filename]' to save to ${CHATS_DIR}/${COLOR_RESET}\n"
  INITIAL_CHAT_PROMPT_FOR_API=$(build_input_string) 

  while true; do
    current_user_input_for_api="" 
    
    if [ -n "$INITIAL_CHAT_PROMPT_FOR_API" ]; then
        debug_log "Using initial prompt/context for the first API call (not echoed)."
        current_user_input_for_api="$INITIAL_CHAT_PROMPT_FOR_API"
        INITIAL_CHAT_PROMPT_FOR_API="" 
    else
        printf "%b" "${COLOR_BRIGHT_BLUE}You: ${COLOR_RESET}" > /dev/tty
        read -er current_user_input_raw < /dev/tty 
        
        if [[ "$current_user_input_raw" == "/q" ]]; then
            printf "%b" "${COLOR_CYAN}Exiting chat.${COLOR_RESET}\n"
            break
        elif [[ "$current_user_input_raw" == "/s"* || "$current_user_input_raw" == "/save"* ]]; then
            arg_filename="" 
            arg_filename=$(echo "$current_user_input_raw" | awk '{print $2}') 

            file_to_save_to_full_path=""
            timestamp=$(date +'%y%m%d-%H%M')

            if [ -n "$arg_filename" ]; then
                safe_arg_filename=$(basename "$arg_filename") 
                file_to_save_to_full_path="${CHATS_DIR}/${timestamp}-${safe_arg_filename}.chat"
                debug_log "Attempting to save chat with new filename: $file_to_save_to_full_path"
            elif [ -n "$LAST_SAVE_FILENAME" ]; then 
                file_to_save_to_full_path="$LAST_SAVE_FILENAME"
                debug_log "Attempting to save chat to existing filename: $file_to_save_to_full_path"
            else 
                file_to_save_to_full_path="${CHATS_DIR}/${timestamp}.chat"
                debug_log "Attempting to save chat with default timestamped filename: $file_to_save_to_full_path"
            fi
            
            if save_chat_to_file "$file_to_save_to_full_path"; then
                LAST_SAVE_FILENAME="$file_to_save_to_full_path" 
                printf "%b" "${COLOR_CYAN}Chat saved to ${file_to_save_to_full_path}${COLOR_RESET}\n" > /dev/tty
            fi
            continue 
        fi
        current_user_input_for_api="$current_user_input_raw" 
    fi

    if [ -z "$current_user_input_for_api" ] && [ ${#CHAT_HISTORY_JSON} -le 2 ]; then 
        debug_log "Chat: Empty input on first turn (after initial prompt processed), skipping API call."
        continue 
    fi
    
    payload=""
    payload=$(build_payload "$current_user_input_for_api") 
    if [ $? -ne 0 ]; then 
        printf "%b" "${COLOR_RED}Error building payload for chat.${COLOR_RESET}\n" > /dev/tty 
        continue
    fi

    # Add user's turn to history
    new_user_part_json=""
    jq_status_nupj=0 
    new_user_part_json=$(jq -n --arg role "user" --rawfile text /dev/stdin '{role: $role, parts: [{text: $text}]}' <<< "$current_user_input_for_api")
    jq_status_nupj=$?
    
    if [ "${jq_status_nupj:-1}" -eq 0 ] && [ -n "$new_user_part_json" ]; then 
        updated_user_history=""
        temp_hist_user_add="" # Removed local
        temp_hist_user_add=$(mktemp)
        printf "%s\n" "$CHAT_HISTORY_JSON" > "$temp_hist_user_add"
        printf "%s\n" "$new_user_part_json" >> "$temp_hist_user_add"
        updated_user_history=$(jq -s '.[0] + [.[1]]' < "$temp_hist_user_add")
        jq_status_update_uh=$? # Removed local
        rm -f "$temp_hist_user_add"

        if [ "${jq_status_update_uh:-1}" -eq 0 ] && [ -n "$updated_user_history" ]; then 
            CHAT_HISTORY_JSON="$updated_user_history"
            debug_log "Updated CHAT_HISTORY_JSON (user part)."
        else
            debug_log "Failed to update CHAT_HISTORY_JSON for user part (jq status: ${jq_status_update_uh:-1}). User part was: $(head -c 100 <<< "$new_user_part_json")..."
        fi
    else
        debug_log "Failed to create new_user_part_json (jq status: ${jq_status_nupj:-1}) or it was empty. User input was: $(head -c 100 <<< "$current_user_input_for_api")..."
    fi

    printf "%b" "${COLOR_BRIGHT_GREEN}Gemini: ${COLOR_RESET}" > /dev/tty 
    
    model_response_text="" 
    send_rc=0 

    if [ "$STREAM_MODE" = true ]; then
      model_response_text_capture=$(handle_stream_request "$payload") 
      send_rc=$? 
      model_response_text="$model_response_text_capture" 
      
      if [ "$MARKDOWN_MODE" = true ] && [ $send_rc -eq 0 ] && [ -n "$model_response_text" ]; then
        printf "\n" > /dev/tty 
        echo "$model_response_text" | "$MARKDOWN_SCRIPT_PATH" > /dev/tty
      fi
      
      if [[ -z "$model_response_text" || "$model_response_text" != *$'\n' ]]; then
          printf "\n" > /dev/tty
      fi

    else 
      model_response_text=$(send_standard_request "$payload") 
      send_rc=$? 
      if [ $send_rc -eq 0 ]; then
        if [ "$MARKDOWN_MODE" = true ] && [ -n "$model_response_text" ]; then
            echo "$model_response_text" | "$MARKDOWN_SCRIPT_PATH" > /dev/tty
        else
            printf "%b" "${COLOR_GREEN}${model_response_text}${COLOR_RESET}\n" > /dev/tty
        fi
      else
        printf "\n" > /dev/tty 
      fi
    fi

    if [ $send_rc -ne 0 ]; then 
        debug_log "API request in chat failed with rc=$send_rc"
        if [ "${jq_status_nupj:-1}" -eq 0 ] && [ -n "$new_user_part_json" ]; then  
             temp_hist_remove="" # Removed local
             temp_hist_remove=$(mktemp)
             printf "%s\n" "$CHAT_HISTORY_JSON" > "$temp_hist_remove" 
             CHAT_HISTORY_JSON=$(jq 'if (length > 0 and .[-1].role == "user") then .[:-1] else . end' < "$temp_hist_remove")
             ps_remove_jq=$? # Removed local
             rm -f "$temp_hist_remove"
             if [ "${ps_remove_jq:-1}" -ne 0 ]; then 
                debug_log "Failed to remove last user message from history after API error. JQ status: ${ps_remove_jq:-1}"
             fi
        fi
        continue
    fi

    # Add model's turn to history
    new_model_part_json=""
    jq_status_nmpj=0 
    new_model_part_json=$(jq -n --arg role "model" --rawfile text /dev/stdin '{role: $role, parts: [{text: $text}]}' <<< "$model_response_text")
    jq_status_nmpj=$?

    if [ "${jq_status_nmpj:-1}" -eq 0 ] && [ -n "$new_model_part_json" ]; then 
        updated_model_history=""
        temp_hist_model_add="" # Removed local
        temp_hist_model_add=$(mktemp)
        printf "%s\n" "$CHAT_HISTORY_JSON" > "$temp_hist_model_add"
        printf "%s\n" "$new_model_part_json" >> "$temp_hist_model_add"
        updated_model_history=$(jq -s '.[0] + [.[1]]' < "$temp_hist_model_add")
        jq_status_update_mh=$? # Removed local
        rm -f "$temp_hist_model_add"
        if [ "${jq_status_update_mh:-1}" -eq 0 ] && [ -n "$updated_model_history" ]; then 
            CHAT_HISTORY_JSON="$updated_model_history"
            debug_log "Updated CHAT_HISTORY_JSON (model part)."
        else
            debug_log "Failed to update CHAT_HISTORY_JSON for model part (jq status: ${jq_status_update_mh:-1}). Model part was: $(head -c 100 <<< "$new_model_part_json")..."
        fi
    else
         debug_log "Failed to create new_model_part_json (jq status: ${jq_status_nmpj:-1}) or it was empty. Model response was: $(head -c 100 <<< "$model_response_text")..."
    fi

  done
else
  # Single request mode (NOT CHAT_MODE)
  INPUT_TEXT_FOR_API=$(build_input_string) 
  PAYLOAD=$(build_payload "$INPUT_TEXT_FOR_API")
  if [ $? -ne 0 ]; then 
    error_exit "Error building payload for single request."
  fi

  if [ "$STREAM_MODE" = true ]; then
    plain_response_text=$(handle_stream_request "$PAYLOAD")
    rc=$?
    if [ $rc -eq 0 ]; then
      if [ "$MARKDOWN_MODE" = true ]; then
        echo "$plain_response_text" | "$MARKDOWN_SCRIPT_PATH" 
      elif [ -t 1 ]; then 
        if [[ -z "$plain_response_text" || "$plain_response_text" != *$'\n' ]]; then
             printf "\n" 
        fi
      else 
        echo "$plain_response_text" 
      fi
    fi
    exit $rc
  else 
    plain_response_text=$(send_standard_request "$PAYLOAD") 
    rc=$?
    if [ $rc -eq 0 ]; then
      if [ "$MARKDOWN_MODE" = true ]; then
        echo "$plain_response_text" | "$MARKDOWN_SCRIPT_PATH" 
      elif [ -t 1 ]; then 
        printf "%b" "${COLOR_GREEN}${plain_response_text}${COLOR_RESET}\n" 
      else 
        echo "$plain_response_text" 
      fi
    fi
    exit $rc
  fi
fi

exit 0

