#!/usr/bin/env bash
# 共享 Docker 启动边界；所有夹具命令使用同一受控网络和安全默认值。
source "$(dirname -- "${BASH_SOURCE[0]}")/docker-network-fixture.sh"

# 有账本时登记具名资源（卷/网络）；无登记目录保持既有行为，不登记不存在的对象。
docker_register_named() {
    local kind=$1 identity=$2 ledger_dir
    [[ -n $identity ]] || return 0
    ledger_dir=$(resource_ledger_dir) || return 0
    RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
    resource_register "$kind" "$identity" "${IT_SCENARIO:-$IT_RUN_ID}" "${IT_ROLE:-$kind}"
}

# 局部删除统一走资源账本：按登记身份与所有权标签交叉验证后精确删除，禁止先删再核验。
integration_remove() {
    local kind=$1 item identity ledger_dir destination rc=0
    shift
    ledger_dir=$(resource_ledger_dir) || return 0
    for item in "$@"; do
        [[ $item != -* && -n $item ]] || continue
        case "$kind" in
            container)
                identity=$(command docker inspect -f '{{.Id}}' "$item" 2>/dev/null) || continue
                [[ -n $identity ]] || continue
                destination=$IT_EVIDENCE_DIR/control/deleted/$identity
                mkdir -p "$destination" || return $?
                command docker inspect "$item" > "$destination/inspect.json" || return $?
                command docker logs "$item" > "$destination/container.log" 2>&1 || return $?
                ;;
            network) identity=$(command docker inspect -f '{{.Id}}' "$item" 2>/dev/null) || continue ;;
            volume) identity=$item ;;
            *) continue ;;
        esac
        [[ -n $identity ]] || continue
        RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
        resource_remove "$kind" "$identity" || rc=$?
    done
    if (( rc != 0 )); then
        printf 'DELETE=%s EXIT=%s\n' "$kind" "$rc" >> "$IT_EVIDENCE_DIR/control/integration-failures.log" || return 2
    fi
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
    # 启动前完成登记；登记失败立即停止，绝不启动未登记对象。
    local ledger_dir
    if ledger_dir=$(resource_ledger_dir); then
        RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
        resource_register container "$id" "${IT_SCENARIO:-$IT_RUN_ID}" "${IT_ROLE:-helper}" || return 2
    fi
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
    if [[ $remove == 1 ]]; then
        if [[ -n ${ledger_dir:-} ]]; then
            RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
            resource_remove container "$id" || return 2
        else
            docker rm "$id" >/dev/null || return 2
        fi
    fi
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
        local vname=''
        vname=$(command docker volume create --label "gitdaemon.run=$IT_RUN_ID" "$@") || return $?
        docker_register_named volume "$vname" || return 2
        printf '%s\n' "$vname"
        return 0
    fi
    if [[ $sub == network && ${2:-} == create ]]; then
        local nid=''
        nid=$(command docker "$@") || return $?
        docker_register_named network "$nid" || return 2
        printf '%s\n' "$nid"
        return 0
    fi
    if [[ $sub == rm || ( ( $sub == volume || $sub == network ) && ${2:-} == rm ) ]]; then
        if [[ $sub == rm ]]; then shift; integration_remove container "$@" || rc=$?
        else shift 2; integration_remove "$sub" "$@" || rc=$?; fi
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
    # 有账本时改为 create→登记→start，启动前完成登记；无登记目录时保持既有 run 语义。
    local ledger_dir
    if ledger_dir=$(resource_ledger_dir); then
        local cid rc=0
        local -a cargs=("${safe[@]}" --network "$network" "${args[@]}" \
            --label "gitdaemon.run=$IT_RUN_ID" \
            --label "gitdaemon.scenario=${IT_SCENARIO:-$IT_RUN_ID}" \
            --label "gitdaemon.role=${IT_ROLE:-product}")
        cid=$(command docker create "${cargs[@]}" "$image" "$@") || return $?
        RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
        resource_register container "$cid" "${IT_SCENARIO:-$IT_RUN_ID}" "${IT_ROLE:-product}" || return 2
        if [[ $detached == 1 ]]; then
            command docker start "$cid" >/dev/null || return $?
            printf '%s\n' "$cid"
        else
            command docker start -a "$cid" || rc=$?
        fi
        if [[ $remove == 1 ]]; then
            RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$IT_RUN_ID
            resource_remove container "$cid" || return 2
        fi
        return "$rc"
    fi
    if [[ $detached == 1 ]]; then args+=(-d); fi
    if [[ $remove == 1 ]]; then args+=(--rm); fi
    command docker run --label "gitdaemon.run=$IT_RUN_ID" "${safe[@]}" --network "$network" "${args[@]}" "$image" "$@"
}
