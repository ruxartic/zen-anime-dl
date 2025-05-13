#!/usr/bin/env bash
#
# Download anime from a Zen API instance
#
#/ Usage:
#/   ./zen-dl.sh -a <anime_name> [-i <anime_id>] [-e <episode_selection>] \
#/               [-r <resolution_keyword>] [-S <server_keyword>] [-o <type>] \
#/               [-L <langs>] [-t <num_threads>] [-l] [-d] [-T <timeout_secs>]
#/
#/ Options:
#/   -a <name>               Anime name to search for (ignored if -i is used).
#/   -i <anime_id>           Specify anime ID directly.
#/   -e <selection>          Episode selection (e.g., "1,3-5", "*", "L3"). Prompts if omitted.
#/   -r <res_keyword>        Optional, keyword for resolution in server name (e.g., "1080", "720").
#/   -S <server_keyword>     Optional, keyword for preferred server (e.g., "HD-1", "HD-2").
#/   -o <type>               Optional, audio type: "sub" or "dub". Default: "sub".
#/   -L <langs>              Optional, subtitle languages (comma-separated codes like "eng,spa",
#/                           or "all", "none", "default"). Default: "default".
#/   -t <num>                Optional, parallel download threads. Default: 4.
#/   -T <secs>               Optional, timeout for segment downloads (GNU Parallel).
#/   -l                      Optional, list m3u8/mp4 links without downloading.
#/   -d                      Enable debug mode.
#/   -h | --help             Display this help message.

# --- Configuration ---
set -e
set -u

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
if ! [ -t 1 ]; then
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  PURPLE=''
  CYAN=''
  BOLD=''
  NC=''
fi

# --- Global Variables ---
_SCRIPT_NAME="$(basename "$0")"

# Default API URL, can be overridden by the ZEN_API_URL environment variable.
_DEFAULT_ZEN_API_BASE_URL="" # <~ edit here to set a default API URL

_ZEN_API_BASE_URL=""
_ANIME_TITLE="unknown_anime"
_ANIME_ID=""
_EPISODE_SELECTION=""
_RESOLUTION_KEYWORD=""
_SERVER_KEYWORD=""
_AUDIO_TYPE="sub"
_SUBTITLE_LANGS_PREF="default"
_NUM_THREADS=4
_SEGMENT_TIMEOUT=""
_LIST_LINKS_ONLY=false
_DEBUG_MODE=false

_VIDEO_DIR_PATH="${ZEN_DL_VIDEO_DIR:-$HOME/Videos/ZenAnime}"
_TEMP_DIR_PARENT="${_VIDEO_DIR_PATH}/.tmp"

_CURL=""
_JQ=""
_FZF=""
_FFMPEG=""
_PARALLEL=""
_MKTEMP=""
all_episodes_json_array_for_padding="[]"

# --- Helper Functions ---
usage() { printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 0; }
print_info() { [[ "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${GREEN}ℹ ${NC}$1" >&2; }
print_warn() { [[ "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${YELLOW}⚠ WARNING: ${NC}$1" >&2; }
print_error() {
  printf "%b\n" "${RED}✘ ERROR: ${NC}$1" >&2
  exit 1
}
print_debug() { [[ "$_DEBUG_MODE" == true && "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${BLUE}DEBUG: ${NC}$1" >&2; }

initialize_api_url() {
  if [[ -n "${ZEN_API_URL:-}" ]]; then
    _ZEN_API_BASE_URL="$ZEN_API_URL"
  elif [[ -n "$_DEFAULT_ZEN_API_BASE_URL" ]]; then
    _ZEN_API_BASE_URL="$_DEFAULT_ZEN_API_BASE_URL"
  else
    _ZEN_API_BASE_URL=""
  fi

  if [[ -z "$_ZEN_API_BASE_URL" ]]; then
    echo -e "${RED}✘ ERROR: Zen API URL is not set.${NC}" >&2
    echo -e "${YELLOW}Please set the ZEN_API_URL environment variable, or ensure _DEFAULT_ZEN_API_BASE_URL is configured in the script.${NC}" >&2
    echo -e "${YELLOW}You can find or self-host the Zen API. Project: https://github.com/PacaHat/zen-api${NC}" >&2
    exit 1
  fi
  _ZEN_API_BASE_URL="${_ZEN_API_BASE_URL%/}" # Remove trailing slash for consistency
}

check_deps() {
  local dep_name tool_path
  print_info "Checking required tools..."
  for dep_name in curl jq fzf ffmpeg parallel mktemp; do
    tool_path=$(command -v "$dep_name") || print_error "$dep_name not found. Please install it."
    declare -g "_${dep_name^^}=$tool_path"
  done
  print_info "${GREEN}✓ All required tools found.${NC}"
}

sanitize_filename() {
  echo "$1" | sed -E 's/[^[:alnum:] ,+\-\)\(._@#%&=]/_/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s '_'
}

# --- Argument Parsing ---
parse_args() {
  OPTIND=1
  while getopts ":hlda:i:e:r:S:o:t:T:L:" opt; do
    case $opt in
    a) _ANIME_SEARCH_NAME="$OPTARG" ;;
    i) _ANIME_ID_ARG="$OPTARG" ;;
    e) _EPISODE_SELECTION="$OPTARG" ;;
    r) _RESOLUTION_KEYWORD="$OPTARG" ;;
    S) _SERVER_KEYWORD="$OPTARG" ;;
    o)
      _AUDIO_TYPE=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]')
      if [[ "$_AUDIO_TYPE" != "sub" && "$_AUDIO_TYPE" != "dub" ]]; then print_error "Invalid audio type. Must be 'sub' or 'dub'."; fi
      ;;
    L)
      _SUBTITLE_LANGS_PREF="$OPTARG"
      print_info "Subtitle language preference: ${_SUBTITLE_LANGS_PREF}"
      ;;
    t)
      _NUM_THREADS="$OPTARG"
      if ! [[ "$_NUM_THREADS" =~ ^[1-9][0-9]*$ ]]; then print_error "-t: Must be positive int."; fi
      ;;
    T)
      _SEGMENT_TIMEOUT="$OPTARG"
      if ! [[ "$_SEGMENT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then print_error "-T: Must be positive int."; fi
      ;;
    l) _LIST_LINKS_ONLY=true ;;
    d)
      _DEBUG_MODE=true
      print_info "${YELLOW}Debug mode enabled.${NC}"
      set -x
      ;;
    h) usage ;;
    \?) print_error "Invalid option: -$OPTARG" ;;
    :) print_error "Option -$OPTARG requires an argument." ;;
    esac
  done
  if [[ -z "${_ANIME_SEARCH_NAME:-}" && -z "${_ANIME_ID_ARG:-}" ]]; then
    print_error "No anime specified (-a or -i required)."
    usage
  fi
  if [[ -n "${_ANIME_SEARCH_NAME:-}" && -n "${_ANIME_ID_ARG:-}" ]]; then
    print_warn "Both -a and -i provided. Using -i (ID: ${_ANIME_ID_ARG})."
    _ANIME_SEARCH_NAME=""
  fi
}

# --- API Interaction ---
api_get_raw() {
  local endpoint_path="$1" query_string="${2:-}" full_url response http_code
  full_url="${_ZEN_API_BASE_URL}${endpoint_path}"
  [[ -n "$query_string" ]] && full_url="${full_url}?${query_string}"
  print_debug "API GET raw: $full_url"
  local curl_stderr_file
  curl_stderr_file="$("$_MKTEMP" --tmpdir zen_dl_curl_stderr.XXXXXX)"
  response=$("$_CURL" -sSL -w "%{http_code}" --connect-timeout 15 --retry 2 --retry-delay 3 \
    -H "Accept: application/json" "$full_url" 2>"$curl_stderr_file")
  local curl_exit_code=$?
  local curl_stderr_output
  curl_stderr_output=$(<"$curl_stderr_file")
  rm -f "$curl_stderr_file"
  if [[ $curl_exit_code -ne 0 ]]; then print_error "curl for $full_url failed (Code: $curl_exit_code). Stderr: $curl_stderr_output"; fi
  http_code="${response:${#response}-3}"
  response="${response:0:${#response}-3}"
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then print_error "API $full_url failed (HTTP: $http_code). Response: $response"; fi
  if ! echo "$response" | "$_JQ" -e .success >/dev/null 2>&1; then
    print_warn "API $full_url response missing '.success' field. Raw: $response"
  elif [[ $(echo "$response" | "$_JQ" -r .success) != "true" ]]; then
    local api_err
    api_err=$(echo "$response" | "$_JQ" -r '.message // .error // "Unknown API error"')
    print_error "API $full_url not successful. Msg: $api_err. Resp: $response"
  fi
  echo "$response"
}

api_get_results() {
  local endpoint_path="$1" query_string="${2:-}" jq_filter="${3:-.results}" raw_response results
  raw_response=$(api_get_raw "$endpoint_path" "$query_string") || return 1
  if ! results=$(echo "$raw_response" | "$_JQ" -e "$jq_filter"); then
    print_error "Failed to extract '$jq_filter' from API for $endpoint_path?$query_string. Raw: $raw_response"
  fi
  echo "$results"
}

# --- Core Logic Functions ---
search_and_select_anime() {
  local search_term="$1" encoded_search_term anime_data_array_json selected_line_from_fzf selected_anime_json
  print_info "Searching for anime: ${BOLD}$search_term${NC}"
  encoded_search_term=$("$_JQ" -nr --arg str "$search_term" '$str|@uri')
  anime_data_array_json=$(api_get_results "/search" "keyword=$encoded_search_term" ".results.data") || return 1
  if [[ -z "$anime_data_array_json" || $(echo "$anime_data_array_json" | "$_JQ" -e 'type != "array" or length == 0') == "true" ]]; then
    print_error "No anime found for '$search_term', or invalid search result format."
  fi
  local jq_preview_filter
  jq_preview_filter='
    "Title:          " + (.title // "N/A") + " (" + (.tvInfo.showType // "N/A") + ")\n" +
    "Japanese Title: " + (.japanese_title // "N/A") + "\n" +
    "ID:             " + (.id // "N/A") + "\n" +
    "Duration:       " + (.duration // "N/A") + "\n" +
    "Episodes:       " + (.tvInfo.eps // "N/A" | tostring) + "\n" +
    "Dub Available:  " + (if .tvInfo.dub != null and .tvInfo.dub > 0 then "Yes (" + (.tvInfo.dub|tostring) + " eps)" else "No" end)
  '
  selected_line_from_fzf=$(echo "$anime_data_array_json" |
    "$_JQ" -r '.[] | ((.title // "N/A") + " (" + (.tvInfo.showType // "N/A") + ")") + "\t" + (.|@json)' |
    "$_FZF" --ansi --height=40% --layout=reverse --info=inline --border --delimiter='\t' \
      --with-nth=1 --header="Search results for '$search_term'" --prompt="Select Anime> " \
      --preview="echo -E {2} | $_JQ -r '$jq_preview_filter'" \
      --preview-window=right:60%:wrap --query="$search_term" --select-1 --exit-0)
  if [[ -z "$selected_line_from_fzf" ]]; then print_error "No anime selected (fzf selection cancelled or empty)."; fi
  selected_anime_json=$(echo -E "$selected_line_from_fzf" | sed 's/^[^\t]*\t//')
  if [[ -z "$selected_anime_json" ]]; then print_error "Failed to extract JSON from fzf selection. Line: [$selected_line_from_fzf]"; fi
  if ! echo "$selected_anime_json" | "$_JQ" -e . >/dev/null 2>&1 || [[ $(echo "$selected_anime_json" | "$_JQ" -r "type") != "object" ]]; then
    print_error "FZF selection not a valid JSON object. Extracted: [$selected_anime_json]"
  fi
  _ANIME_ID=$("$_JQ" -r '.id' <<<"$selected_anime_json")
  _ANIME_TITLE=$("$_JQ" -r '.title // .id' <<<"$selected_anime_json")
  if [[ -z "$_ANIME_ID" || "$_ANIME_ID" == "null" ]]; then print_error "Could not extract anime ID. JSON: [$selected_anime_json]"; fi
  _ANIME_TITLE=$(sanitize_filename "${_ANIME_TITLE}")
  print_info "${GREEN}✓ Selected Anime:${NC} ${BOLD}${_ANIME_TITLE}${NC} (ID: ${_ANIME_ID})"
}

fetch_anime_title_by_id() {
  local anime_id_to_fetch="$1" info_json
  print_info "Fetching details for anime ID: ${BOLD}$anime_id_to_fetch${NC}"
  info_json=$(api_get_results "/info" "id=$anime_id_to_fetch" ".results.data") || return 1
  _ANIME_TITLE=$("$_JQ" -r '.title // .id' <<<"$info_json")
  _ANIME_TITLE=$(sanitize_filename "${_ANIME_TITLE}")
  print_info "${GREEN}✓ Anime Title:${NC} ${BOLD}${_ANIME_TITLE}${NC} (ID: $anime_id_to_fetch)"
}

get_episode_info_list() {
  local current_anime_id="$1" episodes_data total_episodes
  print_info "Fetching episode list for ${BOLD}${_ANIME_TITLE}${NC}..."
  episodes_data=$(api_get_results "/episodes/$current_anime_id" "" ".results") || return 1
  total_episodes=$("$_JQ" -r '.totalEpisodes // 0' <<<"$episodes_data")
  if [[ "$total_episodes" -eq 0 ]]; then
    print_warn "No episodes found for $_ANIME_TITLE."
    echo "[]"
    return 0
  fi
  print_info "Found ${BOLD}$total_episodes${NC} episodes."
  all_episodes_json_array_for_padding=$("$_JQ" -c '[.episodes[] | {ep_num: (.episode_no | tostring), stream_id: .id, title: .title}]' <<<"$episodes_data")
  echo "$all_episodes_json_array_for_padding"
}

parse_episode_selection() {
  local selection_str="$1" all_episodes_json="$2" available_ep_nums_array=()
  local selected_episode_objects_json="[]" include_nums=() exclude_nums=() final_ep_nums=()
  mapfile -t available_ep_nums_array < <(echo "$all_episodes_json" | "$_JQ" -r '.[].ep_num' | sort -n)
  if [[ ${#available_ep_nums_array[@]} -eq 0 ]]; then
    print_warn "No available episodes for selection."
    echo "[]"
    return 0
  fi
  print_debug "Parsing selection: '$selection_str'. Available: ${available_ep_nums_array[*]}"
  IFS=',' read -ra parts <<<"$selection_str"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | tr -d '[:space:]')
    local target_list_ref="include_nums" pattern="$part"
    if [[ "$pattern" == "!"* ]]; then
      target_list_ref="exclude_nums"
      pattern="${pattern#!}"
    fi
    case "$pattern" in
    \*) if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${available_ep_nums_array[@]}"); else exclude_nums+=("${available_ep_nums_array[@]}"); fi ;;
    L[0-9]*)
      local n=${pattern#L}
      if [[ "$n" -gt 0 ]]; then
        mapfile -t slice < <(printf '%s\n' "${available_ep_nums_array[@]}" | tail -n "$n")
        if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${slice[@]}"); else exclude_nums+=("${slice[@]}"); fi
      else print_warn "Invalid L N: $pattern"; fi
      ;;
    F[0-9]*)
      local n=${pattern#F}
      if [[ "$n" -gt 0 ]]; then
        mapfile -t slice < <(printf '%s\n' "${available_ep_nums_array[@]}" | head -n "$n")
        if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${slice[@]}"); else exclude_nums+=("${slice[@]}"); fi
      else print_warn "Invalid F N: $pattern"; fi
      ;;
    [0-9]*-)
      local s=${pattern%-}
      for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -ge "$s" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done
      ;;
    -[0-9]*)
      local e=${pattern#-}
      for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -le "$e" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done
      ;;
    [0-9]*-[0-9]*)
      local s e
      s=$(awk -F- '{print $1}' <<<"$pattern")
      e=$(awk -F- '{print $2}' <<<"$pattern")
      if [[ "$s" =~ ^[0-9]+$ && "$e" =~ ^[0-9]+$ && $s -le $e ]]; then for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -ge "$s" && "$ep" -le "$e" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done; else print_warn "Invalid range: $pattern"; fi
      ;;
    [0-9]*)
      local found=0
      for avail_ep in "${available_ep_nums_array[@]}"; do if [[ "$avail_ep" == "$pattern" ]]; then
        found=1
        break
      fi; done
      if [[ $found -eq 1 ]]; then if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$pattern"); else exclude_nums+=("$pattern"); fi; else print_warn "Ep $pattern not found in available list."; fi
      ;;
    *) print_warn "Unrecognized pattern: $pattern" ;;
    esac
  done
  mapfile -t unique_includes < <(printf '%s\n' "${include_nums[@]}" | sort -n -u)
  mapfile -t unique_excludes < <(printf '%s\n' "${exclude_nums[@]}" | sort -n -u)
  for inc_ep in "${unique_includes[@]}"; do
    local is_excluded=false
    for exc_ep in "${unique_excludes[@]}"; do if [[ "$inc_ep" == "$exc_ep" ]]; then
      is_excluded=true
      break
    fi; done
    [[ "$is_excluded" == false ]] && final_ep_nums+=("$inc_ep")
  done
  if [[ ${#final_ep_nums[@]} -eq 0 ]]; then
    print_warn "No episodes remaining after parsing selection."
    echo "[]"
    return 0
  fi
  local jq_ep_nums_array_str
  jq_ep_nums_array_str=$("$_JQ" -ncR '[inputs]' < <(printf "%s\n" "${final_ep_nums[@]}"))
  selected_episode_objects_json=$("$_JQ" -c --argjson nums_to_select "$jq_ep_nums_array_str" '[.[] | select(.ep_num as $ep | $nums_to_select | index($ep) != null)]' <<<"$all_episodes_json")
  print_debug "Selected episode objects JSON: [$selected_episode_objects_json]"
  if ! echo "$selected_episode_objects_json" | "$_JQ" -e 'type == "array"' >/dev/null 2>&1; then
    print_warn "Episode selection resulted in non-array. Final JSON: $selected_episode_objects_json"
    selected_episode_objects_json="[]"
  fi
  print_info "${GREEN}✓ Episodes to download:${NC} ${BOLD}$(echo "$selected_episode_objects_json" | "$_JQ" -r '[.[].ep_num] | join(", ") // "None"') (Total: $(echo "$selected_episode_objects_json" | "$_JQ" -r '. | length // 0'))${NC}"
  echo "$selected_episode_objects_json"
}

get_stream_details() {
  local ep_stream_id="$1" audio_pref="$2" res_keyword="$3" server_keyword="$4" ep_num_for_log="${5:-}"
  local path_id_part_for_servers query_string_for_servers available_servers_json servers_for_audio_type
  local fzf_input_servers filtered_servers selected_server_line chosen_server_api_name chosen_server_display_name
  local stream_data_results_json encoded_ep_stream_id_for_stream_query query_params streaming_link_obj
  local video_url video_type subtitle_tracks_json subtitles_for_result iframe_url
  print_debug "Fetching stream details for Ep ${ep_num_for_log:-$ep_stream_id} (Type: $audio_pref)..."
  if [[ "$ep_stream_id" == *\?* ]]; then
    path_id_part_for_servers="${ep_stream_id%%\?*}"
    query_string_for_servers="${ep_stream_id#*\?}"
  else
    path_id_part_for_servers="$ep_stream_id"
    query_string_for_servers=""
  fi
  print_debug "  For /servers/: path_id=[$path_id_part_for_servers], query_str=[$query_string_for_servers]"
  available_servers_json=$(api_get_results "/servers/$path_id_part_for_servers" "$query_string_for_servers" ".results") || return 1
  print_debug "  Raw available_servers_json from /servers/: [$available_servers_json]"
  if [[ -z "$available_servers_json" || $("$_JQ" -e 'type != "array" or length == 0' <<<"$available_servers_json") == "true" ]]; then
    print_warn "  No servers found or invalid format for ep $ep_stream_id via /api/servers/."
    return 1
  fi
  servers_for_audio_type=$("$_JQ" -c --arg type "$audio_pref" '[.[] | select(.type == $type)]' <<<"$available_servers_json")
  if [[ $("$_JQ" -e 'length == 0' <<<"$servers_for_audio_type") == "true" ]]; then
    print_warn "  No servers of type '$audio_pref' for ep $ep_stream_id."
    return 1
  fi
  fzf_input_servers=$("$_JQ" -r '.[] | "\(.serverName // "N/A") (\(.type // "N/A"))|\(.serverName // "N/A" | ascii_downcase | gsub(" "; "-"))"' <<<"$servers_for_audio_type")
  filtered_servers="$fzf_input_servers"
  [[ -n "$server_keyword" ]] && filtered_servers=$(echo "$filtered_servers" | grep -iF "$server_keyword")
  [[ -n "$res_keyword" ]] && filtered_servers=$(echo "$filtered_servers" | grep -iF "$res_keyword")
  if [[ -z "$filtered_servers" ]]; then
    filtered_servers="$fzf_input_servers"
    if [[ -z "$filtered_servers" ]]; then
      print_warn "  No servers for '$audio_pref'."
      return 1
    fi
  fi
  selected_server_line=$(echo "$filtered_servers" | head -n 1)
  if [[ -z "$selected_server_line" ]]; then
    print_warn "  Could not select server."
    return 1
  fi
  chosen_server_display_name=$(echo "$selected_server_line" | awk -F'|' '{print $1}')
  chosen_server_api_name=$(echo "$selected_server_line" | awk -F'|' '{print $2}')
  print_info "  Selected server: ${BOLD}${chosen_server_display_name}${NC} (API: $chosen_server_api_name)"
  encoded_ep_stream_id_for_stream_query=$("$_JQ" -nr --arg str "$ep_stream_id" '$str|@uri')
  query_params="id=$encoded_ep_stream_id_for_stream_query&server=${chosen_server_api_name}&type=${audio_pref}"
  print_debug "  Calling /stream with query: [$query_params]"
  stream_data_results_json=$(api_get_results "/stream" "$query_params" ".results") || return 1
  print_debug "  Raw /stream .results: [$stream_data_results_json]"
  streaming_link_obj=$("$_JQ" -c '.streamingLink' <<<"$stream_data_results_json")
  if [[ "$streaming_link_obj" == "null" || $("$_JQ" -e 'type != "object" or (keys_unsorted | length == 0)' <<<"$streaming_link_obj") == "true" ]]; then
    print_warn "  No valid 'streamingLink' from /stream for server '$chosen_server_display_name'."
    print_debug "  Raw /stream .results: $stream_data_results_json"
    return 1
  fi
  iframe_url=$("$_JQ" -r '.iframe // empty' <<<"$streaming_link_obj")
  video_url=$("$_JQ" -r '.link.file' <<<"$streaming_link_obj")
  video_type=$("$_JQ" -r '.link.type' <<<"$streaming_link_obj")
  subtitle_tracks_json=$("$_JQ" -c '.tracks // []' <<<"$streaming_link_obj")
  if [[ "$video_url" == "null" || -z "$video_url" ]]; then
    print_warn "  Video URL empty."
    return 1
  fi
  print_info "    ${GREEN}✓ Video URL:${NC} $video_url (Type: $video_type)"
  [[ -n "$iframe_url" && "$iframe_url" != "null" ]] && print_debug "    Iframe URL: $iframe_url"
  subtitles_for_result=$("$_JQ" -c '[.[]? | select(.file? and .file != "" and .kind == "captions") | {label: .label, url: .file, default: .default?}]' <<<"$subtitle_tracks_json")
  "$_JQ" -ncr --arg vu "$video_url" --arg vt "$video_type" --argjson subs "$subtitles_for_result" --arg ifu "$iframe_url" '{video_url: $vu, video_type: $vt, subtitles: $subs, iframe_url: $ifu}'
}

download_file() {
  local url="$1"
  local outfile="$2"
  local is_m3u8_related="${3:-false}"

  local max_retries=3
  local attempt=0
  local success=false

  mkdir -p "$(dirname "$outfile")"

  local curl_opts_array=()
  curl_opts_array+=(-sSL --fail -o "$outfile" "$url")
  curl_opts_array+=(--connect-timeout 15 --retry 2 --retry-delay 2)

  if [[ -n "$_SEGMENT_TIMEOUT" ]]; then
    curl_opts_array+=(--max-time "$_SEGMENT_TIMEOUT")
  fi
  if [[ "$is_m3u8_related" == "true" ]]; then
    curl_opts_array+=(-H "Accept: */*")
  fi

  print_debug "    Curl opts for $(basename "$outfile"): ${curl_opts_array[*]}"

  for ((attempt = 1; attempt <= max_retries; attempt++)); do
    "$_CURL" "${curl_opts_array[@]}"
    if [[ $? -eq 0 && -s "$outfile" ]]; then
      success=true
      break
    else
      print_warn "    DL attempt $attempt/$max_retries for $(basename "$outfile") failed. Retrying..." >&2
      rm -f "$outfile"
      sleep 2
    fi
  done

  if [[ "$success" == false ]]; then
    rm -f "$outfile"
    return 1
  fi
  return 0
}

download_and_assemble_m3u8() {
  local master_m3u8_url="$1"
  local output_video_path="$2"
  local temp_dir="$3"

  local master_playlist_file="${temp_dir}/master.m3u8"
  local selected_media_playlist_url=""
  local media_playlist_file="${temp_dir}/media_playlist.m3u8"
  local segment_list_file="${temp_dir}/segments.txt"

  print_info "  Downloading Master M3U8..."
  print_debug "    M3U8 URL: $master_m3u8_url (fixed headers)"
  if ! download_file "$master_m3u8_url" "$master_playlist_file" true; then
    return 1
  fi

  local available_streams=()
  local stream_info_line=""
  print_debug "  Parsing master playlist..."
  while IFS= read -r line; do
    if [[ "$line" == \#EXT-X-STREAM-INF:* ]]; then stream_info_line="$line"; elif [[ -n "$stream_info_line" && "$line" != \#* && -n "$line" ]]; then
      local res bw url
      res=$(echo "$stream_info_line" | sed -n 's/.*RESOLUTION=\([^,]*\).*/\1/p')
      bw=$(echo "$stream_info_line" | sed -n 's/.*BANDWIDTH=\([^,]*\).*/\1/p')
      url="$line"
      if [[ -n "$res" && -n "$bw" && -n "$url" ]]; then available_streams+=("${res}|${bw}|${url}"); fi
      stream_info_line=""
    fi
  done <"$master_playlist_file"

  if [[ ${#available_streams[@]} -eq 0 ]]; then
    print_debug "  No variants in master. Assuming media playlist."
    cp "$master_playlist_file" "$media_playlist_file"
    selected_media_playlist_url="$master_m3u8_url"
  else
    print_debug "  Available streams from master:"
    for stream_data in "${available_streams[@]}"; do print_debug "    - Res: $(echo "$stream_data" | awk -F'|' '{print $1}'), BW: $(echo "$stream_data" | awk -F'|' '{print $2}'), URL: $(echo "$stream_data" | awk -F'|' '{print $3}')"; done
    local chosen_stream_data=""
    if [[ -n "$_RESOLUTION_KEYWORD" ]]; then
      print_debug "  Selecting by res keyword: '$_RESOLUTION_KEYWORD'"
      for stream_data in "${available_streams[@]}"; do
        local res
        res=$(echo "$stream_data" | awk -F'|' '{print $1}')
        if [[ "$res" == *$_RESOLUTION_KEYWORD* ]]; then
          chosen_stream_data="$stream_data"
          print_debug "    Matched: $res"
          break
        fi
      done
      if [[ -z "$chosen_stream_data" ]]; then print_warn "    No stream matched res '$_RESOLUTION_KEYWORD'. Falling back."; fi
    fi
    if [[ -z "$chosen_stream_data" ]]; then
      print_debug "  Selecting highest bandwidth..."
      chosen_stream_data=$(printf '%s\n' "${available_streams[@]}" | sort -t'|' -k2,2nr | head -n1)
    fi
    local chosen_res chosen_bw chosen_rel_url
    chosen_res=$(echo "$chosen_stream_data" | awk -F'|' '{print $1}')
    chosen_bw=$(echo "$chosen_stream_data" | awk -F'|' '{print $2}')
    chosen_rel_url=$(echo "$chosen_stream_data" | awk -F'|' '{print $3}')
    print_info "  Selected Stream Quality: ${BOLD}${chosen_res}${NC} (BW: ${chosen_bw})"
    print_debug "    Relative URL: ${chosen_rel_url}"
    local master_m3u8_base_url
    master_m3u8_base_url=$(dirname "$master_m3u8_url")
    if [[ "$chosen_rel_url" =~ ^https?:// ]]; then selected_media_playlist_url="$chosen_rel_url"; else selected_media_playlist_url="${master_m3u8_base_url%/}/${chosen_rel_url#/}"; fi
    print_info "  Downloading Media Playlist..."
    print_debug "    Media Playlist URL: $selected_media_playlist_url"
    if ! download_file "$selected_media_playlist_url" "$media_playlist_file" true; then
      print_warn "  Failed media playlist DL: $selected_media_playlist_url"
      return 1
    fi
  fi

  local media_playlist_base_url
  media_playlist_base_url=$(dirname "$selected_media_playlist_url")

  local segment_urls_for_dl=()
  local local_segment_files_for_ffmpeg=()
  local segment_lines=()

  mapfile -t segment_lines < <(grep -v '^#EXT' "$media_playlist_file" | grep -v '^$' | grep -v '^#')

  if [[ ${#segment_lines[@]} -eq 0 ]]; then
    print_warn "  No segment data lines in: $media_playlist_file"
    print_debug "Content of $media_playlist_file:"
    cat "$media_playlist_file" >&2
    return 1
  fi

  print_info "  Found ${#segment_lines[@]} segments to download."
  for seg_path_or_url in "${segment_lines[@]}"; do
    local full_seg_url segment_filename
    seg_path_or_url=$(echo "$seg_path_or_url" | xargs)
    if [[ -z "$seg_path_or_url" ]]; then continue; fi
    if [[ "$seg_path_or_url" =~ ^https?:// ]]; then full_seg_url="$seg_path_or_url"; else full_seg_url="${media_playlist_base_url%/}/${seg_path_or_url#/}"; fi
    segment_urls_for_dl+=("$full_seg_url")
    segment_filename=$(basename "$seg_path_or_url")
    segment_filename="${segment_filename%%\?*}"
    local_segment_files_for_ffmpeg+=("${temp_dir}/${segment_filename}")
    printf "file '%s'\n" "${segment_filename}" >>"$segment_list_file"
  done

  if [[ ${#segment_urls_for_dl[@]} -eq 0 ]]; then
    print_warn "  No valid segment URLs extracted."
    return 1
  fi

  print_info "  Downloading ${#segment_urls_for_dl[@]} segments using $_NUM_THREADS threads..."
  export _CURL _SEGMENT_TIMEOUT temp_dir
  export -f download_file print_warn print_debug
  local parallel_joblog="${temp_dir}/parallel_dl.log" parallel_input_file="${temp_dir}/parallel_input.txt"
  >"$parallel_input_file"
  for i in "${!segment_urls_for_dl[@]}"; do printf "%s\t%s\t%s\n" "${segment_urls_for_dl[i]}" "${local_segment_files_for_ffmpeg[i]}" "true" >>"$parallel_input_file"; done

  if [[ ! -s "$parallel_input_file" ]]; then
    print_warn "  Parallel input file empty."
    return 1
  fi

  "$_PARALLEL" --colsep '\t' -j "$_NUM_THREADS" --eta --joblog "$parallel_joblog" download_file {1} {2} {3} <"$parallel_input_file"

  local successful_dl
  successful_dl=$(awk 'NR > 1 && $7 == 0 {c++} END {print c+0}' "$parallel_joblog")

  if [[ "$successful_dl" -ne "${#segment_urls_for_dl[@]}" ]]; then
    print_warn "  $((${#segment_urls_for_dl[@]} - successful_dl)) segment(s) failed. Log: $parallel_joblog"
    return 1
  fi

  print_info "  ${GREEN}✓ Segments downloaded.${NC}"
  print_info "  Assembling video: $(basename "$output_video_path")"
  local ffmpeg_log="${temp_dir}/ffmpeg.log"

  if (cd "$temp_dir" && "$_FFMPEG" -y -f concat -safe 0 -i "$(basename "$segment_list_file")" -c copy "$output_video_path" >"$ffmpeg_log" 2>&1); then
    print_info "  ${GREEN}✓ Video assembled.${NC}"
  else
    print_warn "  ffmpeg assembly failed. Log: $ffmpeg_log"
    cat "$ffmpeg_log" >&2
    rm -f "$output_video_path"
    return 1
  fi
  return 0
}

download_episode() {
  local ep_info_json="$1"
  local stream_details_json="$2"

  local ep_num title video_url video_type subtitles_json anime_dir padded_ep_num
  local output_filename_base output_video_path temp_episode_dir
  local success=false

  ep_num=$("$_JQ" -r '.ep_num' <<<"$ep_info_json")
  title=$("$_JQ" -r '.title // "Episode $ep_num"' <<<"$ep_info_json")
  title=$(sanitize_filename "$title")

  video_url=$("$_JQ" -r '.video_url' <<<"$stream_details_json")
  video_type=$("$_JQ" -r '.video_type' <<<"$stream_details_json")
  subtitles_json=$("$_JQ" -c '.subtitles' <<<"$stream_details_json")

  anime_dir="${_VIDEO_DIR_PATH}/${_ANIME_TITLE}"
  mkdir -p "$anime_dir"

  local total_eps_for_padding
  total_eps_for_padding=$(echo "$all_episodes_json_array_for_padding" | "$_JQ" -r '. | length')
  if [[ "$total_eps_for_padding" -gt 999 && ${#ep_num} -lt 4 ]]; then
    padded_ep_num=$(printf "%04d" "$ep_num")
  elif [[ "$total_eps_for_padding" -gt 99 && ${#ep_num} -lt 3 ]]; then
    padded_ep_num=$(printf "%03d" "$ep_num")
  elif [[ "$total_eps_for_padding" -gt 9 && ${#ep_num} -lt 2 ]]; then
    padded_ep_num=$(printf "%02d" "$ep_num")
  else
    padded_ep_num="$ep_num"
  fi

  output_filename_base="${anime_dir}/Episode_${padded_ep_num}_${title}"
  output_video_path="${output_filename_base}.mp4"

  if [[ -f "$output_video_path" ]]; then
    print_info "${GREEN}✓ Ep ${ep_num} already exists. Skipping.${NC}"
    return 0
  fi

  print_info "Processing Episode ${BOLD}$ep_num${NC}: ${BOLD}$title${NC}"

  if [[ "$_LIST_LINKS_ONLY" == true ]]; then
    echo "Anime: $_ANIME_TITLE"
    echo "Episode $ep_num: $title"
    echo "  Video URL ($video_type): $video_url"
    if echo "$subtitles_json" | "$_JQ" -e '. | type=="array" and length > 0' >/dev/null; then
      echo "$subtitles_json" | "$_JQ" -r '.[] | "  Subtitle (\(.label // "N/A")): \(.url // "N/A")"'
    else
      echo "  No subtitles listed or subtitles JSON is not an array."
    fi
    return 0
  fi

  mkdir -p "$_TEMP_DIR_PARENT"
  temp_episode_dir=$("$_MKTEMP" -d "${_TEMP_DIR_PARENT}/zen_dl_${_ANIME_ID}_ep${ep_num}_XXXXXX")
  if [[ -z "$temp_episode_dir" || ! -d "$temp_episode_dir" ]]; then
    print_error "Failed to create temporary directory for episode $ep_num."
    return 1
  fi
  print_debug "  Temp dir: $temp_episode_dir"

  if [[ "$video_type" == "hls" || "$video_url" == *.m3u8* ]]; then
    if download_and_assemble_m3u8 "$video_url" "$output_video_path" "$temp_episode_dir"; then
      success=true
    fi
  elif [[ "$video_type" == "mp4" || "$video_url" == *.mp4* ]]; then
    print_info "  Downloading direct MP4..."
    print_debug "    MP4 URL: $video_url"
    if download_file "$video_url" "$output_video_path" false; then
      success=true
    fi
  else
    print_warn "  Unsupported video type '$video_type' for $video_url. Attempting direct download."
    if download_file "$video_url" "$output_video_path" false; then
      success=true
    fi
  fi

  if [[ "$success" == true ]]; then
    print_info "${GREEN}✓ Downloaded Ep ${ep_num} to $(basename "$output_video_path")${NC}"
    print_debug "Raw \$subtitles_json before processing: [$subtitles_json]"

    if [[ "$_SUBTITLE_LANGS_PREF" == "none" ]]; then
      print_info "  Subtitle download skipped (preference: 'none')."
    else
      local subtitles_to_download_json_array="[]"
      if ! echo "$subtitles_json" | "$_JQ" -e '. | type=="array"' >/dev/null; then
        print_warn "  Subtitles data is not a valid JSON array. Skipping subtitle download."
        subtitles_json="[]"
      fi

      if [[ "$_SUBTITLE_LANGS_PREF" == "default" ]]; then
        subtitles_to_download_json_array=$("$_JQ" --argjson subs "$subtitles_json" -n '$subs | if type=="array" and length>0 then [.[0]] else [] end')
      elif [[ "$_SUBTITLE_LANGS_PREF" == "all" ]]; then
        subtitles_to_download_json_array="$subtitles_json"
        print_debug "  Selected ALL available subtitles."
      else
        local temp_subs_array="[]"
        for lang_code_pref in "${wanted_langs_array[@]}"; do
          local found_sub
          found_sub=$("$_JQ" --argjson subs "$subtitles_json" --arg lang "$lang_code_pref" -c '$subs | map(select(.label | test($lang; "i") or .lang | test($lang; "i"))) | .[0] // empty')
          if [[ -n "$found_sub" ]]; then
            temp_subs_array=$("$_JQ" -c '. + [$found_sub]' <<<"$temp_subs_array")
            print_debug "  Found subtitle for lang '$lang_code_pref'."
          else
            print_debug "  No subtitle found for lang '$lang_code_pref'."
          fi
        done
        subtitles_to_download_json_array="$temp_subs_array"
      fi

      local sub_idx=0
      print_debug "Final subs to DL JSON: $subtitles_to_download_json_array"
      if echo "$subtitles_to_download_json_array" | "$_JQ" -e '. | type=="array" and length > 0' >/dev/null; then
        echo "$subtitles_to_download_json_array" | "$_JQ" -c '.[]?' | while IFS= read -r sub_obj_json; do
          sub_idx=$((sub_idx + 1))
          local sub_url sub_label sub_ext sub_filename
          sub_url=$("$_JQ" -r '.url // empty' <<<"$sub_obj_json")
          sub_label=$("$_JQ" -r '.label // "sub"' <<<"$sub_obj_json")
          sub_label=$(sanitize_filename "$sub_label")

          if [[ -z "$sub_url" || "$sub_url" == "null" ]]; then
            print_warn "  Subtitle $sub_idx ('$sub_label') has no URL. Skipping."
            continue
          fi

          if [[ "$sub_url" == *.vtt ]]; then
            sub_ext="vtt"
          elif [[ "$sub_url" == *.srt ]]; then
            sub_ext="srt"
          elif [[ "$sub_url" == *.ass ]]; then
            sub_ext="ass"
          else
            sub_ext="vtt"
            print_warn "  Unknown subtitle extension for $sub_url, assuming .vtt"
          fi

          sub_filename="${output_filename_base}.${sub_label}.${sub_ext}"

          print_info "  Downloading subtitle $sub_idx: $sub_label ($sub_ext)"
          print_debug "    Subtitle URL: $sub_url"
          print_debug "    Output path: $sub_filename"
          if download_file "$sub_url" "$sub_filename" false; then
            print_info "    ${GREEN}✓ Subtitle '$sub_label' downloaded.${NC}"
          else
            print_warn "    Failed to download subtitle '$sub_label' from $sub_url."
          fi
        done
      else
        print_debug "  No subtitles selected or an issue with the subtitles_to_download_json_array."
      fi
    fi
  else
    print_warn "Failed to download video for Ep $ep_num."
    rm -f "$output_video_path"
  fi

  if [[ -d "$temp_episode_dir" ]]; then
    if [[ "$_DEBUG_MODE" == true ]]; then
      print_warn "  Debug: Leaving temp dir: $temp_episode_dir"
    else
      print_debug "  Cleaning temp dir: $temp_episode_dir"
      rm -rf "$temp_episode_dir"
    fi
  fi

  [[ "$success" == true ]] && return 0 || return 1
}

main() {
  initialize_api_url

  echo -e "\n${PURPLE}========================================${NC}"
  echo -e "${BOLD}${CYAN}      Zen API Anime Downloader        ${NC}"
  echo -e "${PURPLE}========================================${NC}\n"

  parse_args "$@"
  check_deps

  mkdir -p "$_VIDEO_DIR_PATH" || print_error "Cannot create video dir: $_VIDEO_DIR_PATH"
  mkdir -p "$_TEMP_DIR_PARENT" || print_error "Cannot create temp parent dir: $_TEMP_DIR_PARENT"

  echo -e "${CYAN}--- Anime Selection ---${NC}"
  if [[ -n "${_ANIME_ID_ARG:-}" ]]; then
    _ANIME_ID="$_ANIME_ID_ARG"
    fetch_anime_title_by_id "$_ANIME_ID"
  elif [[ -n "${_ANIME_SEARCH_NAME:-}" ]]; then
    search_and_select_anime "$_ANIME_SEARCH_NAME"
  else
    print_error "No anime specified. Should be caught by parse_args."
  fi

  echo -e "\n${CYAN}--- Episode Information ---${NC}"
  local all_episodes_json
  all_episodes_json=$(get_episode_info_list "$_ANIME_ID")
  if [[ $("$_JQ" -r '. | length' <<<"$all_episodes_json") -eq 0 ]]; then
    print_info "No episodes found for ${_ANIME_TITLE}. Exiting."
    exit 0
  fi

  local target_episodes_json
  if [[ -z "$_EPISODE_SELECTION" ]]; then
    print_info "Available episodes for ${BOLD}$_ANIME_TITLE${NC}:"
    echo "$all_episodes_json" | "$_JQ" -r '.[] | .ep_num + " " + (.title // ("Episode " + .ep_num))' |
      awk '{ printf "  [%3s] %s\n", $1, substr($0, index($0,$2)) }' >&2
    local user_selection
    read -r -p "$(echo -e "${YELLOW}▶ Enter episode selection (e.g., 1, 3-5, *, L2):${NC} ")" user_selection
    if [[ -z "$user_selection" ]]; then print_error "No episode selection provided."; fi
    _EPISODE_SELECTION="$user_selection"
  fi
  print_info "Episode selection string: ${BOLD}$_EPISODE_SELECTION${NC}"
  target_episodes_json=$(parse_episode_selection "$_EPISODE_SELECTION" "$all_episodes_json")
  if [[ $("$_JQ" -r '. | length' <<<"$target_episodes_json") -eq 0 ]]; then
    print_info "No episodes selected based on input. Exiting."
    exit 0
  fi

  echo -e "\n${CYAN}--- Starting Downloads ---${NC}"
  local total_sel_eps success_count=0 failure_count=0 current_ep_idx=0
  total_sel_eps=$("$_JQ" -r '. | length' <<<"$target_episodes_json")

  echo "$target_episodes_json" | "$_JQ" -c '.[]?' | while IFS= read -r ep_to_dl_json; do
    [[ -z "$ep_to_dl_json" ]] && continue
    current_ep_idx=$((current_ep_idx + 1))
    local ep_num_log stream_id_ep
    ep_num_log=$("$_JQ" -r '.ep_num' <<<"$ep_to_dl_json")
    stream_id_ep=$("$_JQ" -r '.stream_id' <<<"$ep_to_dl_json")

    echo -e "\n${PURPLE}>>> Processing Episode ${ep_num_log} (${current_ep_idx}/${total_sel_eps}) <<<${NC}"
    local stream_details
    stream_details=$(get_stream_details "$stream_id_ep" "$_AUDIO_TYPE" "$_RESOLUTION_KEYWORD" "$_SERVER_KEYWORD" "$ep_num_log")
    if [[ -z "$stream_details" ]]; then
      print_warn "Could not get stream details for Ep $ep_num_log. Skipping."
      failure_count=$((failure_count + 1))
      continue
    fi
    if download_episode "$ep_to_dl_json" "$stream_details"; then success_count=$((success_count + 1)); else failure_count=$((failure_count + 1)); fi
  done

  echo -e "\n${PURPLE}========================================${NC}"
  echo -e "${BOLD}${CYAN}         Download Summary             ${NC}"
  echo -e "${PURPLE}========================================${NC}"
  print_info "Total episodes planned:   $total_sel_eps"
  [[ "$success_count" -gt 0 ]] && print_info "${GREEN}Successfully downloaded:  $success_count episode(s)${NC}"
  [[ "$failure_count" -gt 0 ]] && print_warn "${RED}Failed/Skipped:         $failure_count episode(s)${NC}"
  echo -e "${PURPLE}========================================${NC}\n"

  if [[ "$failure_count" -gt 0 ]]; then exit 1; fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
