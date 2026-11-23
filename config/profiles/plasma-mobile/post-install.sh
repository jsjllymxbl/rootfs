#!/bin/sh
# plasma-mobile 收尾：建用户、加组、设密码和 tinydm 会话。
set -eu

user=${DESKTOP_USER:-aries}
password=${DESKTOP_PASSWORD:-123456}
session=/usr/share/wayland-sessions/plasma-mobile.desktop

if ! id "$user" >/dev/null 2>&1; then
	echo "==> 建用户 $user"
	adduser -D -u 1000 -s /bin/sh "$user"
fi

for g in audio video input render plugdev netdev wheel; do
	grep -q "^$g:" /etc/group || continue
	addgroup "$user" "$g" >/dev/null 2>&1 || true
done

printf '%s:%s\n' "$user" "$password" | chpasswd
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL) ALL\n' "$user" > "/etc/sudoers.d/$user"
chmod 0440 "/etc/sudoers.d/$user"

# skel 只带配置文件，实际目录在这里建好
install -d -o "$user" -g "$user" -m 0700 "/home/$user/.config"
for d in Desktop Downloads Templates Public Documents Music Pictures Videos; do
	install -d -o "$user" -g "$user" -m 0755 "/home/$user/$d"
done

# base 的 tty 触摸键盘会占 /dev/fb0、/dev/tty0，与 kwin_wayland 冲突
rc-update del buffyboard default 2>/dev/null || true

if [ ! -e "$session" ]; then
	echo "ERROR: 缺 $session" >&2
	exit 1
fi
tinydm-set-session -f -s "$session"
printf '%s\n' "$user" > /etc/default-user

echo "==> plasma-mobile 就绪：用户 $user，会话 $(basename "$session")"
