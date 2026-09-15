#!/bin/bash
# Create and manage Dell TechDirect production support requests.

set -o pipefail
umask 077

# configuration ---------------------------------------------------------------

declare -A req_urls
req_urls=( [curl]="https://curl.se/"
           [jq]="https://jqlang.github.io/jq/" )

readonly token_url=https://apigtwb2c.us.dell.com/auth/oauth/v2/token
readonly webcase_url=https://apigtwb2c.us.dell.com/td/PROD/webcase
readonly getcase_url=https://apigtwb2c.us.dell.com/td/PROD/getcaselite
readonly attachment_url=https://apigtwb2c.us.dell.com/PROD/TDAttachment
readonly attachment_poll_attempts=40
readonly attachment_poll_interval=3

json=0
dump=0
script_dir=$(dirname "$(readlink -m "$0")")
credentials_file=$script_dir/.creds
response=""
http_status=""
tmp_dir=""
auth_header=""
auth_retry=0

# functions -------------------------------------------------------------------

err() {
    local message=$*
    if [[ $json == 1 ]]; then
        jq -nc --arg error "$message" '{error: $error}'
    else
        echo "Error: $message" >&2
    fi
    exit 1
}

debug() {
    [[ ${DEBUG:-0} == 1 ]] && echo "Debug: $*" >&2
}

check_req() {
    local program
    for program in "$@"; do
        type "$program" &>/dev/null || \
            err "$program not found (${req_urls[$program]})"
    done
}

usage() {
    local script=${0##*/}
    cat << EOU
Usage:  $script [-j] [-d] COMMAND [ARGS]

        -j  output JSON
        -d  write the last raw API response to dell_sr_dump.json

Commands:
  auth
      Check OAuth authentication.

  register CLIENT_JSON
      Register the WebCase client. Run this once.

  create CASE_JSON
      Create a support request, or append to the active request for the
      payload's service tag.

  get SR_NUMBER SERVICE_TAG
      Retrieve a support request and its activities.

  note SR_NUMBER TEXT|@FILE
      Append a note of at most 10,000 characters.
      Prefix text with @@ to preserve one leading @ character.

  attach SR_NUMBER EMAIL FILE
      Upload a supporting file in 20 MiB chunks.

  close CLOSE_JSON CONFIRM_SR_NUMBER
      Close a support request. The confirmation must match srNumber in JSON.

Set DELL_SR_CLIENTID and DELL_SR_SECRET to provide credentials directly.
The credential file must contain one client_id:client_secret line and must
not be readable by group or others.

Set DEBUG=1 to print methods, URLs, and HTTP statuses. Secrets are not traced.
EOU
}

cleanup() {
    [[ -n $tmp_dir && -d $tmp_dir ]] && rm -rf -- "$tmp_dir"
}

check_credential_permissions() {
    local file=$1 mode
    mode=$(stat -c '%a' "$file" 2>/dev/null) || err "cannot stat credential file $file"
    (( (8#$mode & 8#077) == 0 )) || \
        err "credential file $file must not be readable or writable by group or others (try chmod 600)"
}

load_credentials() {
    local credentials
    if [[ -n ${DELL_SR_CLIENTID:-} || -n ${DELL_SR_SECRET:-} ]] && \
       [[ -z ${DELL_SR_CLIENTID:-} || -z ${DELL_SR_SECRET:-} ]]; then
        err "set both DELL_SR_CLIENTID and DELL_SR_SECRET, or neither"
    fi
    if [[ -n ${DELL_SR_CLIENTID:-} && -n ${DELL_SR_SECRET:-} ]]; then
        oauth_client_id=$DELL_SR_CLIENTID
        oauth_secret=$DELL_SR_SECRET
        return
    fi

    [[ -r $credentials_file ]] || \
        err "API credentials not found (set DELL_SR_CLIENTID and DELL_SR_SECRET, or create $credentials_file)"
    check_credential_permissions "$credentials_file"
    credentials=$(<"$credentials_file")
    credentials=${credentials//$'\r'/}
    [[ $credentials != *$'\n'* && $credentials == *:* ]] || \
        err "credential file must contain one client_id:client_secret line"
    oauth_client_id=${credentials%%:*}
    oauth_secret=${credentials#*:}
    [[ -n $oauth_client_id && -n $oauth_secret ]] || err "credential file is incomplete"
}

valid_json_file() {
    local file=$1
    [[ -r $file ]] || err "cannot read JSON file $file"
    jq -es 'length == 1 and (.[0] | type == "object")' "$file" &>/dev/null || \
        err "$file must contain exactly one JSON object"
}

write_auth_header() {
    printf 'Authorization: Bearer %s\n' "$token" > "$auth_header"
    chmod 600 "$auth_header"
}

raw_call() {
    local method=$1 url=$2 body_file=${3:-} content_type=${4:-application/json}
    local response_file=$tmp_dir/response curl_rc
    local -a curl_args
    curl_args=( --silent --show-error --proto '=https'
                --connect-timeout 10 --max-time 180
                --request "$method" --url "$url"
                --header "@$auth_header" --header 'Accept: application/json'
                --output "$response_file" --write-out '%{http_code}' )
    if [[ -n $body_file ]]; then
        curl_args+=( --header "Content-Type: $content_type" --data-binary "@$body_file" )
    fi
    debug "$method $url"
    http_status=$(curl "${curl_args[@]}")
    curl_rc=$?
    (( curl_rc == 0 )) || err "request failed ($method $url, curl exit $curl_rc)"
    response=$(<"$response_file")
    debug "HTTP $http_status"
    if [[ $dump == 1 ]]; then
        printf '%s\n' "$response" > dell_sr_dump.json
        chmod 600 dell_sr_dump.json
    fi
    if (( http_status == 401 && auth_retry == 0 )); then
        auth_retry=1
        debug "cached OAuth token rejected; refreshing once"
        get_token refresh
        raw_call "$method" "$url" "$body_file" "$content_type"
        return
    fi
    if (( http_status < 200 || http_status >= 300 )); then
        local api_message
        api_message=$(jq -r '.message // .error_description // .error // .fault.faultstring // empty' \
            <<< "$response" 2>/dev/null)
        [[ -n $api_message ]] || api_message=${response:-empty response}
        err "Dell API returned HTTP $http_status: $api_message"
    fi
}

json_call() {
    local method=$1 url=$2 body=${3:-}
    local body_file=""
    if [[ -n $body ]]; then
        body_file=$tmp_dir/request.json
        printf '%s' "$body" > "$body_file"
    fi
    raw_call "$method" "$url" "$body_file" application/json
    if [[ -n $response ]]; then
        jq empty <<< "$response" 2>/dev/null || err "Dell API returned non-JSON data"
    fi
}

get_token() {
    local force=${1:-} cache_root cache_file cache_tmp now expires cached_client
    local token_response form_file encoded_client_id encoded_secret
    cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/dell-techdirect
    cache_file=$cache_root/token.json
    mkdir -p "$cache_root" || err "cannot create token cache directory $cache_root"
    chmod 700 "$cache_root"
    now=$(date +%s)

    if [[ $force != refresh && -r $cache_file ]]; then
        check_credential_permissions "$cache_file"
        expires=$(jq -r '.expires_at // 0' "$cache_file" 2>/dev/null)
        cached_client=$(jq -r '.client_id // ""' "$cache_file" 2>/dev/null)
        if [[ $expires =~ ^[0-9]+$ ]] && (( expires > now + 60 )) && \
           [[ $cached_client == "$oauth_client_id" ]]; then
            token=$(jq -r '.access_token // ""' "$cache_file")
            [[ -n $token ]] && { debug "using cached OAuth token"; write_auth_header; return; }
        fi
    fi

    form_file=$tmp_dir/oauth-form
    encoded_client_id=$(printf '%s' "$oauth_client_id" | jq -sRr @uri)
    encoded_secret=$(printf '%s' "$oauth_secret" | jq -sRr @uri)
    printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
        "$encoded_client_id" "$encoded_secret" > "$form_file"
    chmod 600 "$form_file"

    # The OAuth request cannot use raw_call because no bearer token exists yet.
    debug "POST $token_url"
    http_status=$(curl --silent --show-error --proto '=https' \
        --connect-timeout 10 --max-time 60 --request POST --url "$token_url" \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary "@$form_file" --output "$tmp_dir/token-response" \
        --write-out '%{http_code}') || err "OAuth request failed"
    token_response=$(<"$tmp_dir/token-response")
    debug "OAuth HTTP $http_status"
    if (( http_status < 200 || http_status >= 300 )); then
        err "OAuth returned HTTP $http_status: $(jq -r '.error_description // .error // .message // "unknown error"' <<< "$token_response" 2>/dev/null)"
    fi
    token=$(jq -r '.access_token // ""' <<< "$token_response")
    [[ -n $token ]] || err "OAuth response did not contain an access token"
    expires=$(jq -r '.expires_in // 3600' <<< "$token_response")
    [[ $expires =~ ^[0-9]+$ ]] || expires=3600
    cache_tmp=$(mktemp "$cache_root/.token.XXXXXX") || err "cannot create token cache file"
    printf '%s\n' "$token" | jq -Rn --arg client_id "$oauth_client_id" \
        --argjson expires_at "$((now + expires))" \
        'input as $access_token |
         {access_token:$access_token,client_id:$client_id,expires_at:$expires_at}' \
        > "$cache_tmp" || err "cannot write token cache"
    chmod 600 "$cache_tmp"
    mv -f "$cache_tmp" "$cache_file"
    write_auth_header
}

show_json_or_summary() {
    local operation=$1
    if [[ $json == 1 ]]; then
        if [[ -n $response ]]; then
            jq . <<< "$response"
        else
            jq -n --arg operation "$operation" --argjson status "$http_status" \
                '{operation:$operation,http_status:$status}'
        fi
        return
    fi
    case $operation in
        auth)
            echo "==========================================="
            echo " Dell TechDirect production"
            echo "==========================================="
            echo " authentication      | successful"
            ;;
        register)
            echo "==========================================="
            echo " WebCase client registration"
            echo "==========================================="
            echo " client ID           | $(jq -r '.id // .clientId // "n/a"' <<< "$response")"
            echo " status              | $(jq -r '.registrationStatus // "n/a"' <<< "$response")"
            ;;
        create)
            echo "==========================================="
            echo " Dell support request"
            echo "==========================================="
            echo " service tag         | $(jq -r '.serviceTag // "n/a"' <<< "$response")"
            echo " warranty status     | $(jq -r '.warrantyStatus // "n/a"' <<< "$response")"
            echo " case status         | $(jq -r '.caseStatus // "n/a"' <<< "$response")"
            echo " SR number           | $(jq -r '.serviceRequest.id // .srNumber // "n/a"' <<< "$response")"
            echo " status              | $(jq -r '.serviceRequest.status // .status // "n/a"' <<< "$response")"
            ;;
        get)
            jq -r '
                (.cases // [])[] |
                "===========================================\n" +
                " Dell support request " + (.id|tostring) + "\n" +
                "===========================================\n" +
                " service tag         | " + (.serviceTag // "n/a") + "\n" +
                " title               | " + (.title // "n/a") + "\n" +
                " severity            | " + (.severityDescription // "n/a") + "\n" +
                " status              | " + (.statusDescription // "n/a") + "\n" +
                " created             | " + (.createdOn // "n/a")
            ' <<< "$response"
            ;;
        note)
            echo " note                | added"
            echo " HTTP status         | $http_status"
            ;;
        attach)
            echo " attachment          | uploaded"
            echo " status              | $(jq -r '.status // "Completed"' <<< "$response")"
            ;;
        close)
            echo " SR number           | $(jq -r '.srNumber // "n/a"' <<< "$response")"
            echo " status              | $(jq -r '.status // "n/a"' <<< "$response")"
            ;;
    esac
}

upload_chunk() {
    local file_id=$1 upload_id=$2 chunk_number=$3 email=$4 chunk=$5 filename=$6
    local response_file=$tmp_dir/response
    local query safe_filename
    query=$(jq -rn --arg f "$file_id" --arg u "$upload_id" --arg c "$chunk_number" \
        '"fileId="+($f|@uri)+"&uploadId="+($u|@uri)+"&chunkNumber="+($c|@uri)')
    debug "POST $attachment_url/public/v3/upload-chunk (chunk $chunk_number)"
    safe_filename=${filename//\\/\\\\}
    safe_filename=${safe_filename//\"/\\\"}
    http_status=$(curl --silent --show-error --proto '=https' \
        --connect-timeout 10 --max-time 300 --request POST \
        --url "$attachment_url/public/v3/upload-chunk?$query" \
        --header "@$auth_header" --header 'Accept: application/json' \
        --form-string "customerEmail=$email" \
        --form "file=@$chunk;filename=\"$safe_filename\"" \
        --output "$response_file" --write-out '%{http_code}') || \
        err "attachment chunk $chunk_number failed"
    response=$(<"$response_file")
    debug "HTTP $http_status"
    (( http_status >= 200 && http_status < 300 )) || \
        err "attachment chunk $chunk_number returned HTTP $http_status: ${response:-empty response}"
}

command_attach() {
    local sr=$1 email=$2 file=$3 size initiate file_id upload_id chunk n complete status_body
    local attempt status
    [[ $sr =~ ^[0-9]+$ ]] || err "invalid SR number ($sr)"
    [[ $email == *@*.* ]] || err "invalid email address ($email)"
    [[ -r $file && -f $file ]] || err "cannot read attachment $file"
    size=$(stat -c '%s' "$file") || err "cannot stat attachment $file"
    (( size > 0 )) || err "attachment must not be empty"
    initiate=$(jq -nc --arg name "${file##*/}" --argjson size "$size" \
        --arg email "$email" --arg sr "$sr" \
        '{fileName:$name,fileSize:$size,customerEmail:$email,serviceRequestNb:$sr}')
    json_call POST "$attachment_url/public/v2/initiate-upload" "$initiate"
    file_id=$(jq -r '.fileId // ""' <<< "$response")
    upload_id=$(jq -r '.uploadId // ""' <<< "$response")
    [[ -n $file_id && -n $upload_id ]] || err "attachment initiation returned no fileId or uploadId"

    mkdir "$tmp_dir/chunks"
    split -b 20971520 -d -a 4 -- "$file" "$tmp_dir/chunks/chunk." || \
        err "could not split attachment into upload chunks"
    n=1
    for chunk in "$tmp_dir"/chunks/chunk.*; do
        upload_chunk "$file_id" "$upload_id" "$n" "$email" "$chunk" "${file##*/}"
        ((n++))
    done

    complete=$(jq -nc --arg email "$email" --arg file "$file_id" --arg upload "$upload_id" \
        '{customerEmail:$email,fileId:$file,uploadId:$upload}')
    json_call POST "$attachment_url/public/v2/upload-complete" "$complete"

    status_body=$(jq -nc --arg email "$email" --arg file "$file_id" \
        '{emailId:$email,fileId:$file}')
    for ((attempt = 1; attempt <= attachment_poll_attempts; attempt++)); do
        json_call POST "$attachment_url/public/v2/file-status" "$status_body"
        status=$(jq -r '.status // "unknown"' <<< "$response")
        [[ $status == Completed ]] && return
        debug "attachment scan pending (attempt $attempt of $attachment_poll_attempts, status $status)"
        (( attempt < attachment_poll_attempts )) && sleep "$attachment_poll_interval"
    done
    err "attachment upload was accepted, but Dell did not finish scanning it after two minutes of polling (last status: $status)"
}

# argument parsing -------------------------------------------------------------

optspec=":hjd"
while getopts "$optspec" option; do
    case $option in
        h) usage; exit 0 ;;
        j) json=1 ;;
        d) dump=1 ;;
        *) usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

command=${1:-}
[[ -n $command ]] || { usage >&2; exit 1; }
shift

check_req curl jq
load_credentials
tmp_dir=$(mktemp -d) || err "cannot create temporary directory"
chmod 700 "$tmp_dir"
auth_header=$tmp_dir/authorization-header
trap cleanup EXIT
if [[ $command == auth ]]; then
    get_token refresh
else
    get_token
fi

# commands --------------------------------------------------------------------

case $command in
    auth)
        [[ $# -eq 0 ]] || err "auth takes no arguments"
        http_status=200
        show_json_or_summary auth
        ;;
    register)
        [[ $# -eq 1 ]] || err "register requires CLIENT_JSON"
        valid_json_file "$1"
        json_call POST "$webcase_url/api/v1/clients" "$(<"$1")"
        show_json_or_summary register
        ;;
    create)
        [[ $# -eq 1 ]] || err "create requires CASE_JSON"
        valid_json_file "$1"
        json_call POST "$webcase_url/api/v1/cases" "$(<"$1")"
        show_json_or_summary create
        ;;
    get)
        [[ $# -eq 2 ]] || err "get requires SR_NUMBER SERVICE_TAG"
        [[ $1 =~ ^[0-9]+$ ]] || err "invalid SR number ($1)"
        [[ $2 =~ ^[A-Za-z0-9]{7}$ ]] || err "invalid service tag ($2)"
        query=$(jq -rn --arg case_id "$1" --arg tag "${2^^}" \
            '"caseId="+($case_id|@uri)+"&serviceTag="+($tag|@uri)')
        json_call GET "$getcase_url/v1/case/getcase?$query"
        show_json_or_summary get
        ;;
    note)
        [[ $# -eq 2 ]] || err "note requires SR_NUMBER TEXT|@FILE"
        [[ $1 =~ ^[0-9]+$ ]] || err "invalid SR number ($1)"
        if [[ $2 == @@* ]]; then
            note_text=${2#@}
        elif [[ $2 == @* ]]; then
            note_file=${2#@}
            [[ -r $note_file && -f $note_file ]] || err "cannot read note file $note_file"
            note_text=$(<"$note_file")
        else
            note_text=$2
        fi
        (( ${#note_text} <= 10000 )) || err "note exceeds 10,000 characters"
        body=$(jq -nc --arg sr "$1" --arg description "$note_text" \
            '{clientType:"HELPDESK",srNumber:$sr,description:$description}')
        json_call POST "$webcase_url/api/v1/cases/activities" "$body"
        show_json_or_summary note
        ;;
    attach)
        [[ $# -eq 3 ]] || err "attach requires SR_NUMBER EMAIL FILE"
        command_attach "$1" "$2" "$3"
        show_json_or_summary attach
        ;;
    close)
        [[ $# -eq 2 ]] || err "close requires CLOSE_JSON CONFIRM_SR_NUMBER"
        valid_json_file "$1"
        expected_sr=$(jq -r '.srNumber // ""' "$1")
        [[ -n $expected_sr && $expected_sr == "$2" ]] || \
            err "confirmation does not match srNumber in $1"
        json_call PUT "$webcase_url/api/v1/cases" "$(<"$1")"
        show_json_or_summary close
        ;;
    *)
        err "unknown command ($command)"
        ;;
esac
