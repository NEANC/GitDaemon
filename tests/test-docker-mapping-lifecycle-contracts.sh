#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'if [[ ${CONTRACT_KEEP:-0} != 1 ]]; then rm -rf "$WORK"; else printf "WORK=%s\n" "$WORK"; fi' EXIT
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
VE_DOCKER_ENDPOINT=unix:///contract-only/docker.sock

# 文件对象模拟 Docker 边界，保留真实编排、握手、校准及账本删除。
lifecycle_docker() {
    local kind=container action=$1 id name='' role='' run='' scenario='' network='' ip='' format='' arg
    printf '%s\n' "$*" >> "$CASE_DIR/docker.log"
    case "$action" in volume|network) kind=$action; shift; action=$1 ;; esac
    shift
    case "$action" in
        create)
            [[ $MODE != prepare-fail ]] || return 42
            id=${*: -1}
            while (( $# )); do
                arg=$1; shift
                case "$arg" in
                    --label)
                        case "$1" in
                            gitdaemon.run=*) run=${1#*=} ;;
                            gitdaemon.scenario=*) scenario=${1#*=} ;;
                            gitdaemon.role=*) role=${1#*=} ;;
                        esac
                        shift ;;
                    --name) name=$1; shift ;;
                    --network) network=$1; shift ;;
                    --ip) ip=$1; shift ;;
                esac
            done
            if [[ $kind == container ]]; then id="id-$GEN-$role"; fi
            [[ ! -f $CASE_DIR/objects/$id ]] || return 98
            printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$scenario" "$role" "$network" "$ip" > "$CASE_DIR/objects/$id"
            if [[ -n $name ]]; then printf '%s\n' "$id" > "$CASE_DIR/names/$name"; fi
            printf '%s\n' "$id" ;;
        inspect)
            if [[ ${1:-} == -f ]]; then format=$2; shift 2; fi
            id=$1
            if [[ $MODE == inspect-error && -f $CASE_DIR/calibrated && $id == *probe ]]; then return 2; fi
            if [[ -f $CASE_DIR/names/$id ]]; then id=$(cat "$CASE_DIR/names/$id"); fi
            [[ -f $CASE_DIR/objects/$id ]] || return 1
            case "$format" in
                '{{.Id}}'|'{{.Name}}') printf '%s\n' "$id" ;;
                *gitdaemon.run*) cut -f1-3 "$CASE_DIR/objects/$id" ;;
                *'.CreatedAt'*'.Driver'*'.Mountpoint'*) printf 'created|local|/contract/%s|labels\n' "$id" ;;
                '{{json .Mounts}}') printf '[{"Destination":"/ev","RW":true}]\n' ;;
                '{{.State.Running}}') [[ -f $CASE_DIR/running/$id ]] && printf 'true\n' ;;
                *) cat "$CASE_DIR/objects/$id" ;;
            esac ;;
        run)
            [[ " $* " == *' --network none '* ]] || return 98
            if [[ " $* " == *' -i '* ]]; then cat >/dev/null; fi
            if [[ " $* " == *' --entrypoint cat '* ]]; then printf 'public-ca\n'; fi ;;
        start)
            id=${*: -1}
            if [[ -f $CASE_DIR/names/$id ]]; then id=$(cat "$CASE_DIR/names/$id"); fi
            IFS=$'\t' read -r run scenario role network ip < "$CASE_DIR/objects/$id"
            if [[ $network != none ]]; then
                [[ ${MAPPING_ACK_GENERATION:-} == "$GEN" ]] || return 98
                [[ $MODE != start-fail ]] || return 42
                if [[ $ip == "$MP_P" ]]; then
                    [[ ! -f $CASE_DIR/p-owner ]] || return 98
                    printf '%s\n' "$id" > "$CASE_DIR/p-owner"
                fi
                printf 'start %s %s\n' "$GEN" "$role" >> "$CASE_DIR/events"
                : > "$CASE_DIR/running/$id"
            fi
            case "$role" in
                evidence-image-check) printf '10001:10001\n' ;;
                evidence-init) printf 'owner=10001:10001\n' ;;
                evidence-verify) printf 'owner=10001:10001\nwrite=PASS\nfifo=PASS\n' ;;
            esac ;;
        exec)
            name=$1; shift
            id=$(cat "$CASE_DIR/names/$name")
            [[ -f $CASE_DIR/running/$id ]] || return 98
            if [[ $1 == curl ]]; then
                [[ $MODE != calibrate-fail ]] || return 42
                if [[ " $* " == *':8443 '* ]]; then
                    printf '1\n' > "$CASE_DIR/accept"
                    printf '%s\n' "$MAPPING_UPSTREAM_HEALTH"
                else
                    printf '1\n' > "$CASE_DIR/reject"
                    printf 'calibrated %s\n' "$GEN" >> "$CASE_DIR/events"
                    : > "$CASE_DIR/calibrated"
                    printf '403\n'; return 22
                fi
            elif [[ $1 == cat ]]; then
                case "$2" in
                    */accept.count) cat "$CASE_DIR/accept" ;;
                    */reject.count) cat "$CASE_DIR/reject" ;;
                    */connect.log) printf 'authority=github.com:443\tmode=accept\tdial_target=%s:443\nauthority=github.com:443\tmode=reject\tdial_target=-\n' "$MP_U" ;;
                    *) return 98 ;;
                esac
            else return 98; fi ;;
        logs) printf '%s\n' "$MAPPING_PRODUCT_READY_MARK" ;;
        rm)
            [[ ${1:-} != -f ]] || shift
            id=${*: -1}
            if [[ -f $CASE_DIR/p-owner && $(cat "$CASE_DIR/p-owner") == "$id" ]]; then rm "$CASE_DIR/p-owner"; fi
            printf 'remove %s\n' "$id" >> "$CASE_DIR/events"
            rm -f "$CASE_DIR/objects/$id" "$CASE_DIR/running/$id" ;;
        ps|ls) return 0 ;;
        *) return 98 ;;
    esac
    return 0
}
validation_docker() { lifecycle_docker "$@"; }
resource_docker() { lifecycle_docker "$@"; }
resource_lock() { return 0; }
resource_unlock() { return 0; }

# 控制端只响应实际请求中的 nonce 和 generation，不设置客户端 ACK。
lifecycle_controller() {
    local request action generation network digest nonce
    while [[ ! -f $CASE_DIR/done ]]; do
        for request in "$IT_CONTROL_DIR"/request-*; do
            [[ -f $request && ! -f ${request/request-/ack-} ]] || continue
            read -r action generation network digest nonce < "$request"
            printf 'ready %s\n' "$generation" >> "$CASE_DIR/events"
            case "$MODE" in wrong-ack) nonce=wrong ;; old-ack) generation=old ;; second-old-ack) [[ $generation != g2 ]] || generation=g1 ;; esac
            printf '%s %s\n' "$nonce" "$generation" > "${request/request-/ack-}.tmp"
            mv "${request/request-/ack-}.tmp" "${request/request-/ack-}"
        done
        sleep 0.02
    done
}

# 两代共用控制根，按登记身份清理后必须重新握手及校准。
lifecycle_case() {
    local MODE=$1 expected=$2 CASE_DIR=$WORK/$1 GEN rc=0 pid generation id
    local IT_CONTROL_DIR=$CASE_DIR/control IT_EVIDENCE_DIR=$CASE_DIR
    local RESOURCE_LEDGER_DIR=$CASE_DIR/control/resources RESOURCE_RUN=mtest
    local MAPPING_PROFILE=$CASE_DIR/profile MAPPING_PRODUCT_IMAGE=product MAPPING_TOOLS_IMAGE=tools
    local MPF_SCENARIO=mapping-fallback
    mkdir -p "$IT_CONTROL_DIR" "$CASE_DIR/objects" "$CASE_DIR/names" "$CASE_DIR/running"
    : > "$CASE_DIR/events"
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    lifecycle_controller & pid=$!
    for generation in 1 2; do
        GEN=g$generation
        MAPPING_ASSERT_GENERATION=$GEN MAPPING_PROXY_RUN_ID=$GEN
        mkdir -p "$CASE_DIR/$GEN"
        printf '0\n' | tee "$CASE_DIR/accept" > "$CASE_DIR/reject"
        rc=0
        mapping_scenario_fixture_prepare fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.prepare" 2>&1 || rc=$?
        if (( rc == 0 )); then mapping_scenario_calibrate fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.calibrate" 2>&1 || rc=$?; fi
        if (( rc == 0 )) && [[ $MODE == drift ]]; then
            printf 'foreign\tmapping-fallback\tprobe\tgm-mtest-m-net\t140.82.112.10\n' > "$CASE_DIR/objects/id-$GEN-probe"
        fi
        if (( rc == 0 )); then mapping_scenario_product_up fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.product" 2>&1 || rc=$?; fi
        if [[ $MODE == second-old-ack && $GEN == g1 ]]; then
            [[ $rc == 0 ]] || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
        else
            printf '%s %s expected=%s actual=%s\n' "$MODE" "$GEN" "$expected" "$rc"
            if [[ $rc != "$expected" ]]; then cat "$CASE_DIR/$GEN."*; : > "$CASE_DIR/done"; wait "$pid"; return 1; fi
        fi
        if (( expected != 0 )) && [[ $MODE != second-old-ack || $GEN == g2 ]]; then
            ! grep -q "^start $GEN product$" "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            if [[ $MODE == drift || $MODE == inspect-error ]]; then
                ! grep -q "^remove id-$GEN-probe$" "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                ! grep -q "^create .*gitdaemon.role=product" "$CASE_DIR/docker.log" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            fi
            if [[ $MODE == second-old-ack ]]; then [[ $GEN == g2 ]] || return 1; fi
            break
        fi
        [[ $(grep -E "^(ready $GEN|start $GEN|calibrated $GEN|remove id-$GEN-probe$)" "$CASE_DIR/events") == "$(printf 'ready %s\nstart %s upstream\nstart %s proxy\nstart %s dns\nstart %s probe\ncalibrated %s\nremove id-%s-probe\nstart %s product' "$GEN" "$GEN" "$GEN" "$GEN" "$GEN" "$GEN" "$GEN" "$GEN")" ]] || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
        for id in "$CASE_DIR/objects/"*; do resource_remove "$(case "${id##*/}" in id-*) printf container ;; gm-*-net) printf network ;; *) printf volume ;; esac)" "${id##*/}" || return 1; done
        rm "$IT_CONTROL_DIR/mapping-fixture.tsv" "$CASE_DIR/calibrated"
    done
    : > "$CASE_DIR/done"
    wait "$pid"
}
failed=0
for spec in ready:0 prepare-fail:80 wrong-ack:80 old-ack:80 second-old-ack:80 start-fail:80 calibrate-fail:80 drift:80 inspect-error:80; do
    ( lifecycle_case "${spec%:*}" "${spec#*:}" ) || failed=1
done
exit "$failed"
