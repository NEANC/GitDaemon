#!/usr/bin/env bash

mapping_upstream_san_volume_script() {
    cat <<'SAN_VOLUME'
set -eu
d="${MAPPING_ASSET_ROOT:?}/upstream/tls"
case "${MAPPING_SAN_ACTION:?}" in
    replace)
        test ! -e "$d/srv.original.crt" && test ! -e "$d/srv.original.key"
        cp "$d/srv.crt" "$d/srv.original.crt"
        trap 'cp "$d/srv.original.crt" "$d/srv.crt"; if test -f "$d/srv.original.key"; then cp "$d/srv.original.key" "$d/srv.key"; fi' EXIT
        cp "$d/srv.key" "$d/srv.original.key"
        work=$(mktemp -d)
        trap 'cp "$d/srv.original.crt" "$d/srv.crt"; cp "$d/srv.original.key" "$d/srv.key"; rm -rf "$work"' EXIT
        openssl req -newkey rsa:2048 -nodes -subj '/CN=other-host.invalid' \
            -keyout "$work/key" -out "$work/req" >/dev/null 2>&1
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:other-host.invalid\n' > "$work/ext"
        openssl x509 -req -in "$work/req" -CA "$d/ca.crt" -CAkey "$d/ca.key" \
            -CAcreateserial -days 2 -extfile "$work/ext" -out "$work/cert" >/dev/null 2>&1
        openssl verify -CAfile "$d/ca.crt" "$work/cert" >/dev/null
        if openssl x509 -in "$work/cert" -noout -checkhost github.com > "$work/hostname"; then exit 1; fi
        grep -q 'does NOT match' "$work/hostname"
        test "$(openssl x509 -in "$work/cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)" = \
            "$(openssl pkey -in "$work/key" -pubout -outform DER | openssl dgst -sha256)"
        cp "$work/cert" "$d/srv.crt"
        cp "$work/key" "$d/srv.key"
        trap - EXIT
        rm -rf "$work"
        ;;
    restore)
        test -f "$d/srv.original.crt" && test -f "$d/srv.original.key"
        cp "$d/srv.original.crt" "$d/srv.crt"
        cp "$d/srv.original.key" "$d/srv.key"
        cmp -s "$d/srv.crt" "$d/srv.original.crt"
        cmp -s "$d/srv.key" "$d/srv.original.key"
        ;;
esac
SAN_VOLUME
}

mapping_upstream_san_volume() {
    local action=${1:-} image=${MAPPING_PRODUCT_IMAGE:-} script
    [[ -n $image && $action =~ ^(replace|restore)$ ]] || return 80
    script=$(mapping_upstream_san_volume_script) || return 80
    printf '%s' "$script" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -e "MAPPING_ASSET_ROOT=$MAPPING_ASSET_ROOT" -e "MAPPING_SAN_ACTION=$action" \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" -s
}

mapping_upstream_san_replace() { mapping_upstream_san_volume replace; }
mapping_upstream_san_restore() { mapping_upstream_san_volume restore; }

mapping_upstream_san_restart() {
    local name
    name=$(mapping_upstream_container) || return 80
    mapping_fixture_docker restart "$name" >/dev/null || return 80
    mapping_fixture_wait "$name" || return 80
}

mapping_upstream_san_leaf() {
    local dir=$1 phase=$2 product=${MAPPING_ASSERT_PRODUCT:-} expected peer observed
    [[ -n $product ]] || return 80
    expected=$(mapping_fixture_docker exec "$(mapping_upstream_container)" openssl x509 \
        -in "$MAPPING_ASSET_ROOT/upstream/tls/srv.crt" -noout -fingerprint -sha256) || return 80
    peer=$(mapping_fixture_docker exec "$product" sh -c \
        'openssl s_client -connect "$1:443" -servername github.com -showcerts </dev/null 2>/dev/null' sh "$MP_U") || return 80
    observed=$(printf '%s\n' "$peer" | openssl x509 -noout -fingerprint -sha256) || return 80
    [[ -n $expected && $observed == "$expected" ]] || return 80
    if [[ $phase == wrong ]]; then
        mapping_fixture_docker exec "$(mapping_upstream_container)" openssl verify \
            -CAfile "$MAPPING_ASSET_ROOT/upstream/tls/ca.crt" \
            "$MAPPING_ASSET_ROOT/upstream/tls/srv.crt" >/dev/null || return 80
    elif [[ $phase == restored ]]; then
        mapping_fixture_docker exec "$(mapping_upstream_container)" cmp -s \
            "$MAPPING_ASSET_ROOT/upstream/tls/srv.crt" "$MAPPING_ASSET_ROOT/upstream/tls/srv.original.crt" || return 80
        mapping_fixture_docker exec "$(mapping_upstream_container)" cmp -s \
            "$MAPPING_ASSET_ROOT/upstream/tls/srv.key" "$MAPPING_ASSET_ROOT/upstream/tls/srv.original.key" || return 80
    fi
    printf '%s\n' "$observed" > "$dir/leaf.$phase" || return 80
    if [[ $phase == wrong ]]; then
        [[ $observed != "$(cat "$dir/leaf.original")" ]] || return 80
    fi
}

mapping_upstream_san_baseline() {
    local dir=$1 kind=$2 scenario=$3 before after rc dial_before dial_after
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    mapping_assert_uint "$before" > "$dir/baseline.before" || return 80
    dial_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_before" >/dev/null || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.before" || return 80
    rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$rc" > "$dir/baseline.exit" || return 80
    [[ $rc == 0 ]] && grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    mapping_assert_uint "$after" > "$dir/baseline.after" || return 80
    (( after > before )) || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.baseline" || return 80
    tail -n "+$(( $(wc -l < "$dir/connect.before") + 1 ))" "$dir/connect.baseline" > "$dir/connect.baseline.new" || return 80
    mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 80
    dial_after=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_after" > "$dir/upstream.baseline" || return 80
    (( dial_after > dial_before )) || return 80
}

mapping_upstream_san_count_after() {
    local kind=$1 scenario=$2 dir=$3 before=$4 after i
    for ((i = 0; i < 20; i++)); do
        after=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
        mapping_assert_uint "$after" >/dev/null || return 80
        if (( after > before )); then printf '%s\n' "$after"; return 0; fi
        sleep 0.5
    done
    return 80
}

mapping_upstream_san_failure() {
    local dir=$1 kind=$2 scenario=$3 before after dial_before dial_after rc
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    dial_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$before" > "$dir/proxy.before" || return 80
    mapping_assert_uint "$dial_before" > "$dir/upstream.before" || return 80
    rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$rc" > "$dir/request.exit" || return 80
    cp "$dir/request.log" "$dir/request.failed.log" || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    dial_after=$(mapping_upstream_san_count_after "$kind" "$scenario" "$dir" "$dial_before") || return 80
    mapping_assert_uint "$after" > "$dir/proxy.after" || return 80
    mapping_assert_uint "$dial_after" > "$dir/upstream.after" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || return 80
    printf 'case\twrong_upstream_san\nlayer\tinner-failure\nconnect_delta\t%s\nrequest_exit\t%s\n' \
        "$((after - before))" "$rc" > "$dir/tls-layer.tsv" || return 80
    (( rc != 0 && after > before && dial_after > dial_before )) || return 1
    tail -n "+$(( $(wc -l < "$dir/connect.baseline") + 1 ))" "$dir/connect.log" > "$dir/connect.failed.new" || return 80
    mapping_assert_connect_legal "$dir/connect.failed.new" "$MP_U" || return 1
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || return 1
    [[ $rc == 60 ]] || return 1
    grep -Eqi 'fatal:.*SSL.*(hostname|subject alternative|certificate.*(match|name))' "$dir/request.failed.log" || return 1
    [[ $(grep -Eoic 'fatal:' "$dir/request.failed.log") == 1 ]] || return 1
    [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
    [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
}

mapping_upstream_san_recovery() {
    local dir=$1 kind=$2 scenario=$3 rc before after
    rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$rc" > "$dir/recovery.exit" || return 80
    [[ $rc == 0 ]] && grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    before=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    mapping_assert_uint "$after" > "$dir/proxy.recovered" || return 80
    (( after > before )) || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.recovered" || return 80
    tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" > "$dir/connect.recovered.new" || return 80
    mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 80
    before=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
    after=$(mapping_upstream_san_count_after "$kind" "$scenario" "$dir" "$before") || return 80
    (( after > before )) || return 80
    [[ -f $dir/refs.expected && -f $dir/head.expected && -f $dir/control/unique-commit ]] || return 80
    mapping_assert_identity_load "$dir" || return 80
    [[ $MPA_UNIQUE_COMMIT == "$(cat "$dir/control/unique-commit")" ]] || return 80
    mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 80
    mapping_scenario_local_refs "$kind" "$scenario" "$dir" > "$dir/refs.actual" || return 80
    mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" || return 80
    mapping_scenario_local_fsck "$kind" "$scenario" "$dir" > "$dir/fsck.exit" || return 80
    mapping_assert_refs_match "$dir" || return 80
    mapping_assert_refs_contain "$dir/refs.actual" "$MPA_UNIQUE_COMMIT" || return 80
    mapping_assert_head_match "$dir" || return 80
    [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 80
}

mapping_upstream_san_case() {
    local dir=$1 kind=$2 scenario=$3 rc=0
    mapping_scenario_valid "$scenario" || return 80
    mapping_profile_load "$MAPPING_PROFILE" || return 80
    mapping_upstream_san_baseline "$dir" "$kind" "$scenario" || return 80
    mapping_upstream_san_leaf "$dir" original || return 80
    printf 'wrong_upstream_san\n' > "$dir/case.tsv" || return 80
    mapping_upstream_san_replace || rc=80
    if (( rc == 0 )); then mapping_upstream_san_restart || rc=80; fi
    if (( rc == 0 )); then mapping_upstream_san_leaf "$dir" wrong || rc=80; fi
    if (( rc == 0 )); then mapping_upstream_san_failure "$dir" "$kind" "$scenario" || rc=$?; fi
    mapping_upstream_san_restore || return 80
    mapping_upstream_san_restart || return 80
    mapping_upstream_san_leaf "$dir" restored || return 80
    cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 80
    if (( rc == 0 )); then mapping_upstream_san_recovery "$dir" "$kind" "$scenario" || return 80; fi
    return "$rc"
}
