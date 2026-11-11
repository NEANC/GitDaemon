#!/usr/bin/env bash

# 在封闭的资产卷内执行证书配对更换或恢复。
mapping_proxy_san_volume() {
    local action=${1:-} image=${MAPPING_PRODUCT_IMAGE:-} script
    [[ -n $image && $action =~ ^(replace|restore)$ ]] || return 80
    script=$(mapping_proxy_san_volume_script) || return 80
    printf '%s' "$script" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -e "MAPPING_ASSET_ROOT=$MAPPING_ASSET_ROOT" -e "MAPPING_SAN_ACTION=$action" \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" -s
}

# 生成仅在卷内运行的签发与恢复脚本。
mapping_proxy_san_volume_script() {
    cat <<'SAN_VOLUME'
set -eu
d="${MAPPING_ASSET_ROOT:?}/proxy/tls"
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
        if openssl x509 -in "$work/cert" -noout -checkhost gm-proxy > "$work/hostname"; then exit 1; fi
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

# 替换为同一 CA 签发的错 SAN 叶证书和配对私钥。
mapping_proxy_san_replace() { mapping_proxy_san_volume replace; }
# 还原原始证书和私钥。
mapping_proxy_san_restore() { mapping_proxy_san_volume restore; }

# 仅重启登记的代理容器并等待服务进程存活。
mapping_proxy_san_restart() {
    local name
    name=$(mapping_proxy_container) || return 80
    mapping_fixture_docker restart "$name" >/dev/null || return 80
    mapping_fixture_wait "$name" || return 80
}

# 比对产品连接收到的叶证书与代理卷内容的指纹。
mapping_proxy_san_leaf() {
    local dir=$1 phase=$2 expected observed product=${MAPPING_ASSERT_PRODUCT:-} peer
    [[ -n $product ]] || return 80
    expected=$(mapping_fixture_docker exec "$(mapping_proxy_container)" openssl x509 \
        -in "$MAPPING_ASSET_ROOT/proxy/tls/srv.crt" -noout -fingerprint -sha256) || return 80
    peer=$(mapping_fixture_docker exec "$product" sh -c \
        'openssl s_client -connect gm-proxy:8443 -servername gm-proxy -showcerts </dev/null 2>/dev/null') || return 80
    observed=$(printf '%s\n' "$peer" | openssl x509 -noout -fingerprint -sha256) || return 80
    [[ -n $expected && $observed == "$expected" ]] || return 80
    if [[ $phase == wrong ]]; then
        mapping_fixture_docker exec "$(mapping_proxy_container)" openssl verify \
            -CAfile "$MAPPING_ASSET_ROOT/proxy/tls/ca.crt" \
            "$MAPPING_ASSET_ROOT/proxy/tls/srv.crt" >/dev/null || return 80
    else
        mapping_fixture_docker exec "$(mapping_proxy_container)" cmp -s \
            "$MAPPING_ASSET_ROOT/proxy/tls/srv.crt" "$MAPPING_ASSET_ROOT/proxy/tls/srv.original.crt" || return 80
        mapping_fixture_docker exec "$(mapping_proxy_container)" cmp -s \
            "$MAPPING_ASSET_ROOT/proxy/tls/srv.key" "$MAPPING_ASSET_ROOT/proxy/tls/srv.original.key" || return 80
    fi
    printf '%s\n' "$observed" > "$dir/leaf.$phase" || return 80
    if [[ $phase == wrong ]]; then
        [[ $observed != "$(cat "$dir/leaf.original")" ]] || return 80
    fi
}

# 从产品容器访问接受端口并验证上游健康内容。
mapping_proxy_san_health() {
    local dir=$1 phase=$2 product=${MAPPING_ASSERT_PRODUCT:-} out
    [[ -n $product ]] || return 80
    out=$(mapping_fixture_docker exec "$product" curl --silent --show-error --fail \
        --connect-timeout 2 --max-time 10 --noproxy '' \
        --proxy "https://$MAPPING_PROXY_HOST:$MAPPING_PROXY_ACCEPT_PORT" \
        --proxy-cacert "$MAPPING_CLIENT_PROXY_CA" --cacert "$MAPPING_CLIENT_UPSTREAM_CA" \
        "https://$MAPPING_UPSTREAM_HOST/health.txt") || return 80
    [[ $out == *"$MAPPING_UPSTREAM_HEALTH"* ]] || return 80
    printf '%s\n' "$out" > "$dir/health.$phase" || return 80
}

# 在产品容器验证受信任代理 CA 下的主机名拒绝，而非仅凭同步摘要推断。
mapping_proxy_san_hostname_probe() {
    local dir=$1 product=${MAPPING_ASSERT_PRODUCT:-} rc=0
    [[ -n $product ]] || return 80
    mapping_fixture_docker exec "$product" curl --verbose --fail --connect-timeout 2 --max-time 10 \
        --noproxy '' --proxy "https://$MAPPING_PROXY_HOST:$MAPPING_PROXY_ACCEPT_PORT" \
        --proxy-cacert "$MAPPING_CLIENT_PROXY_CA" --cacert "$MAPPING_CLIENT_UPSTREAM_CA" \
        "https://$MAPPING_UPSTREAM_HOST/health.txt" > "$dir/hostname.log" 2>&1 || rc=$?
    if [[ $rc == 1 ]]; then
        grep -Eqi 'docker|daemon|exec failed|context deadline' "$dir/hostname.log" && return 80
    fi
    [[ $rc != 28 && $rc != 124 && $rc != 125 && $rc != 126 && $rc != 127 ]] || return 80
    [[ $rc == 60 ]] || return 1
    grep -Eqi 'hostname|subject alternative|certificate.*(match|name)' "$dir/hostname.log" || return 1
}

# 核对恢复后的本地 Git 引用、HEAD 与 fsck。
mapping_proxy_san_recovery_git() {
    local dir=$1 kind=$2 scenario=$3
    mapping_scenario_local_refs "$kind" "$scenario" "$dir" > "$dir/refs.actual" || return 80
    mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" || return 80
    mapping_scenario_local_fsck "$kind" "$scenario" "$dir" > "$dir/fsck.exit" || return 80
    mapping_assert_refs_match "$dir" || return 80
    mapping_assert_head_match "$dir" || return 80
    [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 80
}

# 单例执行并无条件清算换证后的状态；断言失败返回 1，夹具及恢复失败返回 80。
mapping_proxy_san_case() {
    local dir=$1 kind=$2 scenario=$3 before after recovered rc=0 request=0 mutated=0
    mapping_proxy_san_health "$dir" baseline || return 80
    mapping_proxy_san_leaf "$dir" original || return 80
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    mapping_assert_uint "$before" > "$dir/baseline.before" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.baseline" || return 80
    [[ $before -gt 0 ]] || return 80
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    mapping_assert_uint "$before" > "$dir/proxy.before" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.before" || return 80
    printf 'wrong_proxy_san\n' > "$dir/case.tsv" || return 80
    mutated=1
    if ! mapping_proxy_san_replace "$dir"; then rc=80; fi
    if (( rc == 0 )); then mapping_proxy_san_restart "$dir" || rc=80; fi
    if (( rc == 0 )); then mapping_proxy_san_leaf "$dir" wrong || rc=80; fi
    if (( rc == 0 )); then
        mapping_proxy_san_hostname_probe "$dir" || { rc=$?; [[ $rc == 80 ]] || rc=1; }
    fi
    if (( rc == 0 )); then
        request=$(mapping_tls_product_request "$dir" "$scenario") || rc=80
        if (( rc == 0 )); then
            printf '%s\n' "$request" > "$dir/request.exit" || rc=80
            cp "$dir/request.log" "$dir/request.failed.log" || rc=80
            after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || rc=80
        fi
        if (( rc == 0 )); then
            printf '%s\n' "$after" > "$dir/proxy.after" || rc=80
            mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || rc=80
        fi
        if (( rc == 0 )); then
            if [[ $request =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
                printf 'case\twrong_proxy_san\nlayer\touter-failure\nconnect_delta\t%s\nrequest_exit\t%s\n' \
                    "$((after - before))" "$request" > "$dir/tls-layer.tsv" || rc=80
                if (( request == 0 || after != before )); then rc=1; fi
            else
                rc=80
            fi
            cmp -s "$dir/connect.before" "$dir/connect.log" || rc=1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || rc=1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || rc=1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || rc=1
            grep -Eqi 'SSL.*(hostname|subject alternative|certificate.*(match|name))' "$dir/request.failed.log" || rc=1
        fi
    fi
    if (( mutated )); then
        local restore_rc=0 restart_rc=0
        mapping_proxy_san_restore "$dir" || restore_rc=80
        mapping_proxy_san_restart "$dir" || restart_rc=80
        (( restore_rc == 0 && restart_rc == 0 )) || return 80
        mapping_proxy_san_leaf "$dir" restored || return 80
        cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 80
        mapping_proxy_san_health "$dir" recovered || return 80
        recovered=$(mapping_tls_product_request "$dir" "$scenario") || return 80
        [[ $recovered == 0 ]] || return 80
        grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
        recovered=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
        [[ $recovered =~ ^[0-9]+$ && $recovered -gt $before ]] || return 80
        printf '%s\n' "$recovered" > "$dir/proxy.recovered" || return 80
        mapping_proxy_san_recovery_git "$dir" "$kind" "$scenario" || return 80
    fi
    return "$rc"
}
