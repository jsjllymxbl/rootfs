#!/bin/sh
# 与 postmarketos-base-ui-qt-wayland 一致：Qt 应用走 Wayland，不叠加标题栏。
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export QT_QPA_PLATFORM=wayland
