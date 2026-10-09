#!/usr/bin/env bash
# 只接受 daemon 明确拒绝服务，不将传输失败算作推送拒绝。
host_push_denied() {
    [[ $1 != 0 && ( $2 == *'access denied'* || $2 == *'remote error: service not enabled:'* ) ]]
}
