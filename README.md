# aries rootfs / TWRP 刷机包

小米 2（aries，APQ8064）主线 Linux 的 Alpine rootfs 与 TWRP 刷机包。

```
bootloader -> lk2nd -> boot.img（[initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）-> /init 挂 userdata(p23)
  -> switch_root 到 <userdata>/rootfs -> /sbin/init
```

## 配置结构

当前只有基础层 `config/base`：

| 文件 | 作用 |
| --- | --- |
| `packages.list` | 从 Alpine 仓库安装的包 |
| `services.list` | `<服务>[:<runlevel>]`，默认 `default` |
| `repositories` | `/etc/apk/repositories` 模板，`@BRANCH@` 由 `APK_BRANCH` 替换 |
| `overlay/` | 直接覆盖到 rootfs 的文件树 |

构建系统支持按层叠加：后续加入的 `config/profiles/<name>` 可带同名字段和
`post-install.sh`（chroot 内执行一次，可用 `LAYER`/`PROFILE` 环境变量），按 `PROFILE`
顺序叠在基础层上；包/服务取并集去重，overlay 后叠覆盖先叠。

## 依赖

`qemu-user-binfmt`、`python3`、`curl`、`tar`、`gzip`、`sudo`。

## 用法

```sh
make                       # 构建 rootfs.tar.gz + TWRP 刷机包
make profiles              # 列出可用层（当前只有 base）
make show                  # 查看合并后的包/服务与产物名
make package PKG=adbd      # 单独编本地包（out/packages/）
make fetch                 # 下载 minirootfs
make rootfs / make zip     # 只构建 rootfs / 只打刷机包
make shell                 # 进 chroot
make check                 # 校验刷机包
make clean / distclean     # 卸载挂载后删除 work/ 和 out/
```

常用变量：

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `PACKAGES` / `ADD_PACKAGES` | 替换 / 追加包清单 | 空 |
| `SERVICES` / `ADD_SERVICES` | 替换 / 追加服务 | 空 |
| `ROOT_PASSWORD` | root 密码（空 = 不设置） | `alpine` |
| `KERNEL_MODULES` | 内核模块目录 | 空 |
| `APK_BRANCH` / `APK_UPGRADE` | Alpine 分支 / 是否升级 | `latest-stable` / `yes` |
| `ALPINE_RELEASE` | 固定 minirootfs 版本 | latest-stable |
| `TARGET_DIR` | 设备安装目录 | `/data/rootfs` |
| `COMPRESS` | `gzip` / `xz` / `none` | `gzip` |

## 目录

```
config/base/              基础层配置（包/服务/仓库源/overlay）
packages/<name>/          本地 apk（armv7 chroot + abuild）
scripts/                  构建、打包、recovery 脚本
work/base/rootfs/         rootfs 构建目录
out/                      rootfs tar、刷机包、本地 apk
```

## 内容

- 基础系统：busybox/openrc、WPA supplicant、dropbear、curl/sudo/nano/htop、e2fsprogs/kmod；
  root 密码 `alpine`，时区 `Asia/Shanghai`，主机名 `aries`。
- `/etc/network/interfaces` 只配置回环，满足 dropbear 的 `need net`；WiFi 手工配。
- 固件由 initramfs 在切根前拷入，rootfs 不带。
- 本地包 `adbd` 来自 `packages/adbd`：静态、免认证、FunctionFS；服务与 USB 看护脚本同包。

## 刷机包

```
aries-alpine-base-<branch>-<date>.zip
├── rootfs-base.tar.gz                 STORED，第一个成员
└── META-INF/com/google/android/{update-binary,updater-script}
```

TWRP 里选 zip 安装；`update-binary` 是 shell 脚本，按偏移取出 tar 解压到 `/data/rootfs`。
刷机包不含 boot.img（见 [initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）。
