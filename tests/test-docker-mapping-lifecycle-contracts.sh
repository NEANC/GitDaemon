#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'if [[ ${CONTRACT_KEEP:-0} != 1 ]]; then rm -rf "$WORK"; else printf "WORK=%s\n" "$WORK"; fi' EXIT
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/docker-network-guard.sh"
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
            [[ $MODE != second-prepare-fail || $GEN != g2 ]] || return 42
            id=${*: -1}
            if [[ $kind == network || $kind == volume ]]; then name=$id; fi
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
            if [[ $kind == container ]]; then id=$(printf '%s' "$GEN-$scenario-$role" | sha256sum); id=${id%% *}; fi
            if [[ $kind == network ]]; then id=$(printf '%s' "$name" | sha256sum); id=${id%% *}; fi
            [[ ! -f $CASE_DIR/objects/$id ]] || return 98
            printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$scenario" "$role" "$network" "$ip" > "$CASE_DIR/objects/$id"
            if [[ -n $name ]]; then printf '%s\n' "$id" > "$CASE_DIR/names/$name"; fi
            printf '%s\n' "$id" ;;
        inspect)
            if [[ ${1:-} == -f ]]; then format=$2; shift 2; fi
            id=$1
            if [[ $MODE == inspect-error && -f $CASE_DIR/calibrated && -f $CASE_DIR/names/gm-mtest-probe && $id == "$(cat "$CASE_DIR/names/gm-mtest-probe")" ]]; then return 2; fi
            if [[ -f $CASE_DIR/names/$id ]]; then id=$(cat "$CASE_DIR/names/$id"); fi
            [[ -f $CASE_DIR/objects/$id ]] || return 1
            case "$format" in
                '{{.Id}}') printf '%s\n' "$id" ;;
                '{{.Name}}') for name in "$CASE_DIR/names/"*; do [[ ! -f $name || $(cat "$name") != "$id" ]] || { printf '%s\n' "${name##*/}"; return 0; }; done; return 1 ;;
                *'HostConfig.NetworkMode'*'gitdaemon.run'*|*'gitdaemon.run'*'HostConfig.NetworkMode'*) IFS=$'\t' read -r run scenario role network ip < "$CASE_DIR/objects/$id"; printf '%s|%s|%s|%s|%s|123|true\n' "$id" "$run" "$scenario" "$role" "$network" ;;
                *'HostConfig.NetworkMode'*) cut -f4 "$CASE_DIR/objects/$id" | while read -r network; do printf '%s|true\n' "$network"; done ;;
                *'NetworkSettings.Networks'*) network=$(cut -f4 "$CASE_DIR/objects/$id"); cat "$CASE_DIR/names/$network" ;;
                *'com.docker.network.bridge.name'*) printf 'mmtest\n' ;;
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
            if [[ $network != none && $role != witness ]]; then
                [[ ${MAPPING_ACK_GENERATION:-} == "$GEN" ]] || return 98
                [[ $MODE != start-fail ]] || return 42
                [[ $MODE != second-start-fail || $GEN != g2 ]] || return 42
                if [[ $ip == "$MP_P" ]]; then
                    [[ ! -f $CASE_DIR/p-owner ]] || return 98
                    printf '%s\n' "$id" > "$CASE_DIR/p-owner"
                fi
                printf 'start %s %s\n' "$GEN" "$role" >> "$CASE_DIR/events"
                : > "$CASE_DIR/running/$id"
            fi
            if [[ $role == witness ]]; then : > "$CASE_DIR/running/$id"; fi
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
                [[ $MODE != second-calibrate-fail || $GEN != g2 ]] || return 42
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
        ps|ls)
            for id in "$CASE_DIR/objects/"*; do
                [[ -f $id ]] || continue
                role=$(cut -f3 "$id")
                if [[ $kind == network ]]; then [[ $role == network || $role == witness-network ]] || continue
                elif [[ $kind == volume ]]; then [[ $role != network && $role != witness-network && $role != witness && ! -f $CASE_DIR/running/${id##*/} ]] || continue
                else [[ $role != network && $role != witness-network && ( $action != ps || -f $CASE_DIR/running/${id##*/} ) ]] || continue; fi
                printf '%s\n' "${id##*/}"
            done ;;
    esac
    return 0
}
validation_docker() { lifecycle_docker "$@"; }
resource_docker() { lifecycle_docker "$@"; }
docker() { lifecycle_docker "$@"; }
iptables() { printf '%s\n' "$*" >> "$CASE_DIR/iptables.log"; }
nsenter() { printf '%s\n' "$*" >> "$CASE_DIR/nsenter.log"; }
resource_lock() { return 0; }
resource_unlock() { return 0; }
guard_mapping_state_write() { printf 'generation\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\n' "$2" "$3" "$4" > "$1"; }
guard_mapping_ack_publish() {
    local nonce=$4 generation=$5
    case "$MODE" in
        wrong-ack) nonce=wrong ;;
        old-ack) generation=old ;;
        second-old-ack) [[ $generation != g2 ]] || generation=g1 ;;
    esac
    printf '%s %s\n' "$nonce" "$generation" > "$1/ack-$3"
}
validation_environment_verify() { return 0; }

# 控制端只响应实际请求中的 nonce 和 generation，不设置客户端 ACK。
lifecycle_controller() {
    local request action generation network digest nonce rc=0
    local seq=1 last_nonce='' rules_start=0 state='' GUARD_MAPPING_CONTROL_IDENTITY=contract
    local E=$CASE_DIR RUN=mtest GUARD_PROFILE=$MAPPING_PROFILE GUARD_MANIFEST=contract GUARD_ATTESTATION=contract
    mapping_profile_load "$GUARD_PROFILE" || return 1
    while [[ ! -f $CASE_DIR/done ]]; do
        for request in "$IT_CONTROL_DIR"/request-*; do
            [[ -f $request && ! -f ${request/request-/ack-} ]] || continue
            read -r action generation network digest nonce < "$request"
            [[ $request == "$IT_CONTROL_DIR/request-$seq" ]] || continue
            if [[ $action == mapping-ready ]]; then printf 'ready %s\n' "$generation" >> "$CASE_DIR/events"; fi
            if [[ $action == mapping-release ]]; then printf 'release %s\n' "$generation" >> "$CASE_DIR/events"; fi
            rc=0
            if [[ $MODE == release-query-fail && $action == mapping-release ]]; then
                resource_enumerate() { return 2; }
            fi
            if [[ $action == mapping-release ]]; then
                printf '%s %s\n' "$(wc -l < "$CASE_DIR/iptables.log")" "$(wc -l < "$CASE_DIR/nsenter.log")" > "$CASE_DIR/rules-before-release"
            fi
            guard_mapping_request_handle "$action" "$generation" "$network" "$digest" "$nonce" || rc=$?
            if [[ $rc == 0 && $action == mapping-ready && ( ${#OWN_RULES[@]} == 0 || ${#OWN_NS_RULES[@]} == 0 ) ]]; then rc=98; fi
            if [[ $rc != 0 ]]; then
                printf 'guard-fail %s %s\n' "$action" "$rc" >> "$CASE_DIR/events"
                : > "$CASE_DIR/done"
            fi
        done
        sleep 0.02
    done
}

# 两代共用控制根，按登记身份清理后必须重新握手及校准。
lifecycle_case() {
    local MODE=$1 expected=$2 CASE_DIR=$WORK/$1 GEN rc=0 pid generation id before
    local IT_CONTROL_DIR=$CASE_DIR/control IT_EVIDENCE_DIR=$CASE_DIR
    local RESOURCE_LEDGER_DIR=$CASE_DIR/control/resources RESOURCE_RUN=mtest
    local MAPPING_PROFILE=$CASE_DIR/profile MAPPING_PRODUCT_IMAGE=product MAPPING_TOOLS_IMAGE=tools
    local MPF_SCENARIO=mapping-fallback E=$CASE_DIR RUN=mtest
    mkdir -p "$IT_CONTROL_DIR" "$CASE_DIR/objects" "$CASE_DIR/names" "$CASE_DIR/running"
    : > "$CASE_DIR/events"
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    lifecycle_controller > "$CASE_DIR/controller.log" 2>&1 & pid=$!
    for generation in 1 2; do
        GEN=g$generation
        MAPPING_ASSERT_GENERATION=$GEN MAPPING_PROXY_RUN_ID=$GEN
        mkdir -p "$CASE_DIR/$GEN"
        printf '0\n' | tee "$CASE_DIR/accept" > "$CASE_DIR/reject"
        rc=0
        mapping_scenario_fixture_prepare fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.prepare" 2>&1 || rc=$?
        if (( rc == 0 )); then mapping_scenario_calibrate fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.calibrate" 2>&1 || rc=$?; fi
        if (( rc == 0 )) && [[ $MODE == success-then-calibrate-fail ]]; then
            MODE=calibrate-fail
            mapping_scenario_calibrate fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.recalibrate" 2>&1 || rc=$?
        fi
        if (( rc == 0 )) && [[ $MODE == drift ]]; then
            id=$(cat "$CASE_DIR/names/gm-mtest-probe")
            printf 'foreign\tmapping-fallback\tprobe\tgm-mtest-m-net\t140.82.112.10\n' > "$CASE_DIR/objects/$id"
        fi
        if (( rc == 0 )); then mapping_scenario_product_up fallback mapping-fallback "$CASE_DIR/$GEN" > "$CASE_DIR/$GEN.product" 2>&1 || rc=$?; fi
        if (( rc == 0 )); then
            [[ -s $CASE_DIR/rules.owned && -s $CASE_DIR/witness-rules.owned ]] || rc=98
        fi
        if [[ $MODE == second-* && $GEN == g1 || $MODE == release-query-fail && $GEN == g1 ]]; then
            [[ $rc == 0 ]] || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
        else
            printf '%s %s expected=%s actual=%s\n' "$MODE" "$GEN" "$expected" "$rc"
            if [[ $rc != "$expected" ]]; then cat "$CASE_DIR/$GEN."*; : > "$CASE_DIR/done"; wait "$pid"; return 1; fi
        fi
        if (( expected != 0 )) && [[ $MODE != second-* && $MODE != release-query-fail || $GEN == g2 ]]; then
            ! grep -q "^start $GEN product$" "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            before=$(wc -l < "$CASE_DIR/docker.log")
            mapping_scenario_product_up fallback mapping-fallback "$CASE_DIR/$GEN" >/dev/null 2>&1 && { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            ! tail -n +"$((before + 1))" "$CASE_DIR/docker.log" | grep -Eq '(^| )(create|start|rm)( |$)' || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            if [[ $MODE == drift || $MODE == inspect-error ]]; then
                ! grep -q "^remove $(cat "$CASE_DIR/names/gm-mtest-probe")$" "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
            fi
            if [[ $MODE == second-* || $MODE == release-query-fail ]]; then [[ $GEN == g2 ]] || return 1; fi
            break
        fi
        id=$(cat "$CASE_DIR/names/gm-mtest-probe")
        [[ $(grep -E "^(ready $GEN|start $GEN|calibrated $GEN|remove $id$)" "$CASE_DIR/events") == "$(printf 'ready %s\nstart %s upstream\nstart %s proxy\nstart %s dns\nstart %s probe\ncalibrated %s\nremove %s\nstart %s product' "$GEN" "$GEN" "$GEN" "$GEN" "$GEN" "$GEN" "$id" "$GEN")" ]] || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
        mapping_scenario_release fallback mapping-fallback "$GEN" "$CASE_DIR/$GEN" || {
            if [[ $MODE == release-query-fail ]]; then
                before=$(wc -l < "$CASE_DIR/docker.log")
                grep -q '^release g1$' "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                grep -q '^guard-fail mapping-release 2$' "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                read -r host_before witness_before < "$CASE_DIR/rules-before-release"
                [[ $(wc -l < "$CASE_DIR/iptables.log") == "$host_before" && $(wc -l < "$CASE_DIR/nsenter.log") == "$witness_before" ]] || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                grep -q "^remove $(cat "$CASE_DIR/names/gm-mtest-g1-product")$" "$CASE_DIR/events" || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                mapping_scenario_fixture_prepare fallback mapping-fallback "$CASE_DIR/g2" >/dev/null 2>&1 && { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                ! tail -n +"$((before + 1))" "$CASE_DIR/docker.log" | grep -Eq '(^| )(create|start|rm)( |$)' || { : > "$CASE_DIR/done"; wait "$pid"; return 1; }
                : > "$CASE_DIR/done"; wait "$pid"; return 0
            fi
            : > "$CASE_DIR/done"; wait "$pid"; return 1
        }
        [[ -f $IT_CONTROL_DIR/generations/$GEN/mapping-fixture.tsv && -f $IT_CONTROL_DIR/generations/$GEN/mapping-network.tsv ]] || return 1
        [[ $(sed -n 's/^generation\t//p' "$IT_CONTROL_DIR/generations/$GEN/mapping-network.tsv") == "$GEN" ]] || return 1
        rm "$CASE_DIR/calibrated"
    done
    : > "$CASE_DIR/done"
    wait "$pid"
}
failed=0
for spec in ${LIFECYCLE_CASES:-ready:0 prepare-fail:80 wrong-ack:80 old-ack:80 second-old-ack:80 start-fail:80 calibrate-fail:80 success-then-calibrate-fail:80 second-prepare-fail:80 second-start-fail:80 second-calibrate-fail:80 drift:80 inspect-error:80 release-query-fail:80}; do
    ( lifecycle_case "${spec%:*}" "${spec#*:}" ) || failed=1
done
exit "$failed"
