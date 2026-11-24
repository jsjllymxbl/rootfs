#!/bin/sh
# tinydm 自动登录到 Plasma Mobile 会话
set -eu

. "${LAYER_LIB:?构建脚本没有注入 LAYER_LIB}"

hook_session plasma-mobile.desktop
