# 登录 shell 的小环境（Alpine 的 /etc/profile 会 source 这一堆）
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export EDITOR=nano

alias ll='ls -lh'
alias l='ls -lha'

if [ "$(id -u)" -eq 0 ]; then
    PS1='\[\e[1;31m\]\h\[\e[0m\]:\w \# '
else
    PS1='\h:\w \$ '
fi
