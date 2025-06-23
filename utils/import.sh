#!/bin/bash

# Declare an associative array to keep track of imported files (absolute paths).
# This prevents infinite recursion and ensures each file is processed only once.
declare -A IMPORTED_FILES

# Array to store the final output blocks. Each block will be a <context/> tag.
# This array is global so it can be populated by recursive calls.
OUTPUT_BLOCKS=()

# import_file() function: Recursively processes a given file, handles import directives,
# and appends its wrapped content to the global OUTPUT_BLOCKS array.
# Arguments:
#   $1: The path to the file to be imported.
import_file() {
    local file_path="$1"
    local abs_path=""

    # Attempt to get the absolute path of the file.
    # `realpath` returns a non-zero exit code and nothing to stdout if the file does not exist or is inaccessible.
    if ! abs_path=$(realpath "$file_path" 2>/dev/null); then
        # If the file path cannot be resolved or the file doesn't exist, skip it.
        # This prevents errors from non-existent files or broken symlinks.
        return 0
    fi

    # Check if this file (by its absolute path) has already been imported.
    # If it has, skip it to prevent infinite recursion and redundant processing.
    if [[ -n "${IMPORTED_FILES[$abs_path]}" ]]; then
        return 0 # File already processed, return.
    fi

    # Mark the current file as imported *before* processing its content.
    # This handles cases where a file might refer to itself or participate in a circular dependency,
    # ensuring it's not processed multiple times within the same recursion path.
    IMPORTED_FILES[$abs_path]=1

    local content_buffer=""               # Stores the content of the current file (excluding import directives).
    local files_to_import_from_current=() # Stores paths of files referenced by '>>$' directives found in this file.

    # Read the entire content of the file.
    # `cat` is used to read the file, and process substitution (`<<<`) feeds it to the `while read` loop.
    # This avoids creating a subshell for the loop, ensuring that `content_buffer` and `files_to_import_from_current`
    # (and `IMPORTED_FILES` via `import_file` calls) are modified in the main shell context.
    local file_content
    if ! file_content=$(cat "$file_path" 2>/dev/null); then
        # If the file cannot be read (e.g., permissions, empty file), remove it from `IMPORTED_FILES`
        # so that it *could* potentially be tried again later if referenced via a different path,
        # or if permissions change (though unlikely in a single run).
        unset IMPORTED_FILES[$abs_path]
        return 1 # Indicate that the file could not be read.
    fi

    # Process the file content line by line.
    while IFS= read -r line; do
        # Check if the line starts with '>>$'.
        # Using bash regex `[[ ... =~ ... ]]` for efficient pattern matching.
        if [[ "$line" =~ ^>>\$ ]]; then
            # This line is an import directive. Extract arguments following '>>$'.
            # `sed` removes the '>>$' prefix, and `xargs` trims leading/trailing whitespace.
            local args_string=$(echo "$line" | sed 's/^>>\$[[:space:]]*//' | xargs)

            # If no arguments follow '>>$', skip this particular import directive.
            if [[ -z "$args_string" ]]; then
                continue
            fi

            # Handle wildcard expansion (globbing) relative to the directory of the *current* file.
            local current_dir="$(dirname "$file_path")"
            local original_pwd="$PWD" # Save the current working directory.

            # Temporarily change directory to resolve relative paths and wildcards correctly.
            # This ensures that `sub/*.md` inside `/path/to/A/file.md` refers to `/path/to/A/sub/*.md`.
            if [[ -d "$current_dir" ]]; then
                pushd "$current_dir" >/dev/null || { echo "Error: Failed to change directory to $current_dir" >&2; continue; }
            fi

            # Enable `nullglob` option: patterns that match no files expand to a null string (empty list).
            # This prevents literal glob patterns (e.g., `*.md`) from being passed as filenames if no matches are found.
            shopt -s nullglob
            
            # Perform word splitting and glob expansion.
            # When `args_string` is unquoted in a `for` loop, bash performs splitting and glob expansion.
            local expanded_args=()
            for token in $args_string; do
                expanded_args+=( "$token" )
            done

            shopt -u nullglob # Disable `nullglob` to restore default shell behavior.

            # Return to the original directory.
            if [[ -d "$current_dir" ]]; then
                popd >/dev/null || { echo "Error: Failed to return from $current_dir" >&2; continue; }
            fi

            # Add the (potentially expanded) paths to the list of files to import from this file.
            # `realpath` will convert these paths to absolute paths when `import_file` is called recursively.
            for imported_arg in "${expanded_args[@]}"; do
                files_to_import_from_current+=( "$imported_arg" )
            done
        else
            # This line is not an import directive; it's part of the regular content of the current file.
            # Append it to the buffer for this file's content, followed by a newline.
            content_buffer+="$line"$'\n'
        fi
    done <<< "$file_content" # Feed the entire `file_content` to the `while read` loop.

    # Remove the trailing newline character from `content_buffer` if it exists.
    # This prevents extra newlines at the end of the wrapped content.
    content_buffer="${content_buffer%$'\n'}"

    # Recursively call `import_file` for all files discovered in the current file's import directives.
    # This ensures a depth-first traversal of the import graph.
    for file_to_import in "${files_to_import_from_current[@]}"; do
        import_file "$file_to_import"
    done

    # After all child imports have been processed and their contexts added to `OUTPUT_BLOCKS`,
    # wrap the current file's content in its `<context>` tag and add it to the global list.
    # This results in a depth-first, post-order traversal in the final output (children contexts before parent).
    OUTPUT_BLOCKS+=( "<context path=\"$abs_path\">$content_buffer</context>" )

    return 0 # Indicate successful processing of the file.
}

# --- Main execution starts here ---

# Check if any initial files are provided as command-line arguments.
if [[ "$#" -eq 0 ]]; then
    # If no files are provided, there's nothing to process as per the specified behavior.
    exit 0
fi

# Iterate over each initial file path provided as an argument to the script.
# Bash automatically performs glob expansion on command-line arguments (e.g., `import.sh *.md`),
# so `$initial_file_arg` will already be an expanded filename if a wildcard was used.
for initial_file_arg in "$@"; do
    import_file "$initial_file_arg"
done

# After all files (initial and recursively imported) have been processed and their
# `<context>` blocks collected, print all accumulated blocks to standard output.
for block in "${OUTPUT_BLOCKS[@]}"; do
    echo "$block"
done
