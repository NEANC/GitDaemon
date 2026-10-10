#!/usr/bin/env bash

gm_state_repo_path() {
    local root=$1 repo=$2 kind=$3 owner name
    [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
    owner=${repo%%/*}
    name=${repo#*/}
    [[ $kind == repos || $kind == operations ]] || return 1
    printf '%s/state/%s/%s/%s.state\n' "$root" "$kind" "$owner" "$name"
}

gm_state_validate_value() {
    local value=$1
    [[ -n $value && $value != *[[:cntrl:]]* && $value != *[[:space:]]* && $value != *=* && $value != *:* ]]
}

gm_state_validate_repo_array() {
    local array_name=$1 key value
    declare -n values=$array_name
    for key in "${!values[@]}"; do
        case "$key" in schema|repo|generation|desired|observed|published|message) ;; *) return 1 ;; esac
    done
    for key in schema repo generation desired observed published message; do
        [[ ${values[$key]+present} ]] || return 1
        value=${values[$key]}
        gm_state_validate_value "$value" || return 1
    done
    [[ ${values[schema]} == 1 ]] || return 1
    [[ ${values[repo]} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
    [[ ${values[generation]} =~ ^[0-9]+$ ]] || return 1
    [[ ${values[desired]} == present || ${values[desired]} == absent ]] || return 1
    [[ ${values[observed]} == ready || ${values[observed]} == syncing || ${values[observed]} == error || ${values[observed]} == missing ]] || return 1
    [[ ${values[published]} == yes || ${values[published]} == no ]]
}

gm_state_read_array() {
    local file=$1 expected_repo=$2 array_name=$3 line key value
    local -A seen=()
    declare -n values=$array_name
    values=()
    gm_validate_file "$file" read || return 1
    [[ -f $file && ! -L $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}
        value=${line#*=}
        [[ $key =~ ^[a-z_]+$ && -z ${seen[$key]+present} ]] || return 1
        gm_state_validate_value "$value" || return 1
        seen[$key]=1
        values[$key]=$value
    done < "$file"
    gm_state_validate_repo_array "$array_name" || return 1
    [[ ${values[repo]} == "$expected_repo" ]]
}

gm_repo_state_read() {
    local repo=$1 array_name=$2 file
    file=$(gm_state_repo_path "${RUN_ROOT:?}" "$repo" repos) || return 1
    gm_state_read_array "$file" "$repo" "$array_name"
}

gm_state_directory_prepare() {
    local path=$1 parent=${1%/*}
    if [[ ! -d $parent ]]; then (umask 077; mkdir -p -- "$parent") || return 1; fi
    gm_validate_path "$parent" || return 1
    if [[ ! -d $path ]]; then (umask 077; mkdir -- "$path") || return 1; fi
    [[ -d $path && ! -L $path ]] || return 1
    gm_validate_path "$path" || return 1
    return 0
}

gm_state_flush() {
    local path=$1
    [[ -e $path || -d $path ]] || return 1
    if [[ ${GM_STATE_TEST_FAULT-} == sync ]]; then return 1; fi
    sync -- "$path" || return 1
    return 0
}

gm_state_write_array_locked() {
    local file=$1 array_name=$2 directory temporary key status
    declare -n values=$array_name
    directory=${file%/*}
    if [[ -e $file || -L $file ]]; then
        gm_validate_file "$file" || return 1
    fi
    temporary=$(mktemp "$directory/.state.XXXXXX") || return 1
    (
        umask 077
        gm_validate_path "$directory" || exit 1
        if [[ ${GM_STATE_TEST_FAULT-} == write ]]; then exit 1; fi
        printf 'schema=%s\nrepo=%s\ngeneration=%s\ndesired=%s\nobserved=%s\npublished=%s\nmessage=%s\n' \
            "${values[schema]}" "${values[repo]}" "${values[generation]}" "${values[desired]}" \
            "${values[observed]}" "${values[published]}" "${values[message]}" > "$temporary"
        gm_state_flush "$temporary" || exit 1
        if [[ ${GM_STATE_TEST_FAULT-} == rename ]]; then exit 1; fi
        mv -f -- "$temporary" "$file" || exit 1
        if [[ ${GM_STATE_TEST_FAULT-} == directory-sync ]]; then exit 2; fi
        gm_state_flush "$directory" || exit 1
    )
    status=$?
    if [[ -e $temporary ]]; then
        rm -f -- "$temporary"
    fi
    (( status == 0 )) || return "$status"
    return 0
}

gm_repo_state_commit_locked() {
    local repo=$1 array_name=$2 file directory owner
    declare -n values=$array_name
    gm_state_validate_repo_array "$array_name" || return 1
    [[ ${values[repo]} == "$repo" ]] || return 1
    file=$(gm_state_repo_path "${RUN_ROOT:?}" "$repo" repos) || return 1
    directory=${file%/*}
    owner=${directory%/*}
    gm_validate_path "$RUN_ROOT" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state/repos" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state/repos/${repo%/*}" || return 1
    gm_state_directory_prepare "$owner" || return 1
    gm_state_directory_prepare "$directory" || return 1
    [[ -d $owner && ! -L $owner ]] || return 1
    [[ -d $directory && ! -L $directory ]] || return 1
    gm_state_write_array_locked "$file" "$array_name"
    return $?
}

gm_operation_commit_locked() {
    local repo=$1 array_name=$2 file directory owner
    declare -n values=$array_name
    gm_state_validate_repo_array "$array_name" || return 1
    [[ ${values[repo]} == "$repo" ]] || return 1
    file=$(gm_state_repo_path "${RUN_ROOT:?}" "$repo" operations) || return 1
    directory=${file%/*}
    owner=${directory%/*}
    gm_validate_path "$RUN_ROOT" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state/operations" || return 1
    gm_state_directory_prepare "${RUN_ROOT}/state/operations/${repo%/*}" || return 1
    gm_state_directory_prepare "$owner" || return 1
    gm_state_directory_prepare "$directory" || return 1
    [[ -d $owner && ! -L $owner ]] || return 1
    [[ -d $directory && ! -L $directory ]] || return 1
    gm_validate_path "$owner" || return 1
    gm_validate_path "$directory" || return 1
    gm_state_write_array_locked "$file" "$array_name"
    return $?
}
