#!/usr/bin/env bash
# 共享 Docker 启动边界；所有夹具命令使用同一受控网络和安全默认值。
source "$(dirname -- "${BASH_SOURCE[0]}")/docker-network-fixture.sh"

# 网络容器注入受控 DNS/IPv6 设置，离线卷操作不附加网络。
docker() {
    if [[ ${IT_NETWORK_LIBRARY_RUN:-0} == 1 ]]; then command docker "$@"; return $?; fi
    local sub=${1:-} arg network=none name='' entry=0 ca=0
    local -a args=() safe=(--user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges)
    if [[ $sub == volume && ${2:-} == create ]]; then
        shift 2
        command docker volume create --label "gitdaemon.run=$IT_RUN_ID" "$@"
        return $?
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
            --entrypoint) entry=1; args+=("$arg" "$1"); shift ;;
            -v|--volume)
                [[ $1 != *:/ca:* ]] || ca=1
                args+=("$arg" "$1"); shift ;;
            --env|-e|--publish|-p|--network-alias|--workdir|-w|--label|--hostname|--tmpfs|--sysctl|--pid)
                args+=("$arg" "$1"); shift ;;
            --*) args+=("$arg") ;;
            -*) args+=("$arg") ;;
            *) args+=("$arg" "$@"); break ;;
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
    command docker run --label "gitdaemon.run=$IT_RUN_ID" "${safe[@]}" --network "$network" "${args[@]}"
}
