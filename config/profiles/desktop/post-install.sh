#!/bin/sh
# 共用桌面层：普通用户、sudo、家目录，关掉 base 的 fb 触摸键盘
set -eu

. "${LAYER_LIB:?构建脚本没有注入 LAYER_LIB}"

hook_user
hook_sudo
hook_home
hook_no_fb_keyboard
