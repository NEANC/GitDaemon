#!/usr/bin/env bash
# 共享 Docker 启动边界；所有夹具命令使用同一受控网络和安全默认值。
source "$(dirname -- "${BASH_SOURCE[0]}")/docker-network-fixture.sh"

# 局部删除前保存原件，正常不存在可跳过，真实错误写入跨进程状态。
integration_remove() {
    local kind=$1 item ids identity destination rc=0
    shift
    for item in "$@"; do
        [[ $item != -* && -n $item ]] || continue
        if [[ $kind == container ]]; then
            ids=$(command docker ps -aq --filter "id=$item") || return $?
            if [[ -z $ids ]]; then ids=$(command docker ps -aq --filter "name=^/$item$") || return $?; fi
        else
            ids=$(command docker volume ls -q --filter "name=^$item$") || return $?
        fi
        [[ -n $ids ]] || continue
        if [[ $kind == container ]]; then
            identity=$(command docker inspect -f '{{.Id}}' "$item") || return $?
            destination=$IT_EVIDENCE_DIR/control/deleted/$identity
            mkdir -p "$destination" || return $?
            command docker inspect "$item" > "$destination/inspect.json" || return $?
            command docker logs "$item" > "$destination/container.log" 2>&1 || return $?
            command docker rm -f "$item" || rc=$?
        else
            command docker volume rm "$item" || rc=$?
        fi
    done
    return "$rc"
}

# 检查辅助容器实际配置，共享命名空间只允许本轮单网络目标。
integration_helper_policy() {
    local id=$1 mode value target networks mount mounts
    mode=$(command docker inspect -f '{{.HostConfig.NetworkMode}}' "$id") || return $?
    value=$(command docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Privileged}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$id") || return $?
    case "$value" in
        '10001:10001 true false [ALL] [no-new-privileges]'|'10001:10001 true false [ALL] [no-new-privileges:true]') ;;
        *) return 1 ;;
    esac
    [[ $(command docker inspect -f '{{.HostConfig.ExtraHosts}} {{.HostConfig.CapAdd}}' "$id") == '[] []' ]] || return 1
    case "$mode" in
        none)
            networks=$(command docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id") || return $?
            [[ ${networks% } == none ]] || return 1
            ;;
        "$IT_NETWORK")
            networks=$(command docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id") || return $?
            [[ ${networks% } == "$IT_NETWORK" ]] || return 1
            [[ $(command docker inspect -f '{{.HostConfig.Dns}}' "$id") == "[$IT_DNS_IP]" ]] || return 1
            [[ $(command docker inspect -f '{{index .HostConfig.Sysctls "net.ipv6.conf.all.disable_ipv6"}}' "$id") == 1 ]] || return 1
            ;;
        container:*)
            target=${mode#container:}
            [[ $(command docker inspect -f '{{index .Config.Labels "gitdaemon.run"}}' "$target") == "$IT_RUN_ID" ]] || return 1
            assert_container_network_configuration "$target" || return $?
            ;;
        *) return 1 ;;
    esac
    if [[ $mode != none ]]; then
        [[ $(command docker network inspect -f '{{.EnableIPv6}}' "$IT_NETWORK") == false ]] || return 1
    fi
    mounts=$(command docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}}{{println}}{{end}}' "$id") || return $?
    while IFS= read -r mount; do
        [[ -z $mount || $mount == "volume gm-$IT_RUN_ID-"* ]] || return 1
    done <<< "$mounts"
}

# 短命客户端改为显式创建和删除，退出前保存实际身份与配置原件。
integration_helper_run() {
    local detached=$1 remove=$2 entrypoint=$3 image=$4 id rc=0 policy=0 destination identity
    shift 4
    local -a options=()
    while [[ $1 != -- ]]; do options+=("$1"); shift; done
    shift
    if [[ $detached == 1 ]]; then
        id=$(command docker create "${options[@]}" --entrypoint "$entrypoint" "$image" "$@") || return $?
    else
        id=$(command docker create "${options[@]}" --entrypoint /bin/sh "$image" -c \
            'printf "HELPER_UID=%s:%s\n" "$(id -ru)" "$(id -u)" >&2; exec "$@"' helper "$entrypoint" "$@") || return $?
    fi
    destination=$IT_EVIDENCE_DIR/control/helpers/$id
    mkdir -p "$destination" || return $?
    command docker inspect "$id" > "$destination/inspect.json" || return $?
    if [[ $detached == 1 ]]; then
        command docker start "$id" >/dev/null || return $?
        integration_helper_policy "$id" || policy=$?
        identity=$(command docker exec "$id" sh -c 'printf "%s:%s" "$(id -ru)" "$(id -u)"') || policy=1
        printf 'HELPER_UID=%s\n' "$identity" > "$destination/identity.txt"
        [[ $identity == 10001:10001 ]] || policy=1
    else
        integration_helper_policy "$id" || policy=$?
        if [[ $policy == 0 ]]; then command docker start -ai "$id" || rc=$?; fi
        command docker logs "$id" > "$destination/container.log" 2>&1 || policy=1
        grep -qx 'HELPER_UID=10001:10001' "$destination/container.log" || policy=1
    fi
    command docker inspect "$id" > "$destination/inspect.json" || policy=1
    printf 'PRIMARY_EXIT=%s\nPOLICY_EXIT=%s\n' "$rc" "$policy" > "$destination/status.txt"
    if [[ $policy != 0 ]]; then
        printf 'HELPER=%s POLICY_EXIT=%s\n' "$id" "$policy" >> "$IT_EVIDENCE_DIR/control/integration-failures.log"
        return 2
    fi
    if [[ $remove == 1 ]]; then docker rm "$id" >/dev/null || return 2; fi
    if [[ $detached == 1 ]]; then printf '%s\n' "$id"; fi
    return "$rc"
}

# 网络容器注入受控 DNS/IPv6 设置，离线卷操作不附加网络。
docker() {
    if [[ ${IT_NETWORK_LIBRARY_RUN:-0} == 1 ]]; then command docker "$@"; return $?; fi
    local sub=${1:-} arg network=none name='' entry=0 ca=0 detached=0 remove=0 entrypoint='' image='' rc=0
    local -a args=() safe=(--user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges)
    if [[ $sub == volume && ${2:-} == create ]]; then
        shift 2
        command docker volume create --label "gitdaemon.run=$IT_RUN_ID" "$@"
        return $?
    fi
    if [[ $sub == rm || $sub == volume && ${2:-} == rm ]]; then
        if [[ $sub == rm ]]; then shift; integration_remove container "$@" || rc=$?
        else shift 2; integration_remove volume "$@" || rc=$?; fi
        if (( rc != 0 )); then
            printf 'DELETE=%s EXIT=%s\n' "$*" "$rc" >> "$IT_EVIDENCE_DIR/control/integration-failures.log" || return 2
        fi
        return "$rc"
    fi
    [[ $sub == run ]] || { command docker "$@"; return $?; }
    shift
    [[ ${IT_NETWORK_GUARD_READY:-} == 1 && -n ${IT_DNS_IP:-} ]] || return 77
    while (( $# )); do
        arg=$1; shift
        case "$arg" in
            --network) network=$1; shift ;;
            --name) name=$1; args+=(--name "$1"); shift ;;
            --user|--cap-drop|--security-opt) shift ;;
            --read-only) ;;
            --entrypoint) entry=1; entrypoint=$1; shift ;;
            -d|--detach) detached=1 ;;
            --rm) remove=1 ;;
            -v|--volume)
                [[ $1 != *:/ca:* ]] || ca=1
                args+=("$arg" "$1"); shift ;;
            --env|-e|--publish|-p|--network-alias|--workdir|-w|--label|--hostname|--tmpfs|--sysctl|--pid)
                args+=("$arg" "$1"); shift ;;
            --*) args+=("$arg") ;;
            -*) args+=("$arg") ;;
            *) image=$arg; break ;;
        esac
    done
    case "$network" in
        none|container:*) ;;
        "$IT_NETWORK")
            safe+=(--dns "$IT_DNS_IP" --sysctl net.ipv6.conf.all.disable_ipv6=1)
            if [[ $ca == 0 ]]; then safe+=(-v "gm-$IT_RUN_ID-ca:/ca:ro"); fi
            ;;
        *) printf '禁止未授权网络：%s\n' "$network" >&2; return 77 ;;
    esac
    if [[ -n $name && $entry == 0 ]]; then
        [[ $network == "$IT_NETWORK" ]] || return 77
        safe+=(--ip 172.30.243.4)
    fi
    if [[ $entry == 1 ]]; then
        integration_helper_run "$detached" "$remove" "$entrypoint" "$image" \
            --label "gitdaemon.run=$IT_RUN_ID" "${safe[@]}" --network "$network" "${args[@]}" -- "$@"
        return $?
    fi
    if [[ $entry == 1 ]]; then args+=(--entrypoint "$entrypoint"); fi
    if [[ $detached == 1 ]]; then args+=(-d); fi
    if [[ $remove == 1 ]]; then args+=(--rm); fi
    command docker run --label "gitdaemon.run=$IT_RUN_ID" "${safe[@]}" --network "$network" "${args[@]}" "$image" "$@"
}
