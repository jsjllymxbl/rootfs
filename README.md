# aries rootfs / TWRP 刷机包

小米 2（aries，APQ8064）主线 Linux 的 Alpine rootfs 与 TWRP 刷机包。

```
bootloader -> lk2nd -> boot.img（[initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）-> /init 挂 userdata(p23)
  -> switch_root 到 <userdata>/rootfs -> /sbin/init
```

## 配置结构

每层可选五个部分：

| 文件 | 作用 |
| --- | --- |
| `packages.list` | 从 Alpine 仓库安装的包 |
| `packages_local.list` | 本地包（格式 `配方:包1,包2,...`，见下） |
| `services.list` | `<服务>[:<runlevel>]`，默认 `default` |
| `overlay/` | 直接覆盖到 rootfs 的文件树 |
| `post-install.sh` | chroot 内执行一次（可用 `LAYER`/`PROFILE`/`DESKTOP_USER`/`DESKTOP_PASSWORD`） |

`config/base` 永远最先叠；`config/profiles/<name>` 按 `PROFILE` 顺序叠加。包/服务取并集
去重，overlay 后叠覆盖先叠。当前有 `plasma-mobile` 桌面层，`base` 是纯基础系统。

`packages_local.list` 的每行是 `配方:包1,包2,...`（或只写配方名）：配方对应
`packages/<配方>/APKBUILD`，冒号后的包才装进 rootfs。例如
`mesa:mesa,mesa-dri-gallium,mesa-egl` 只构建 `packages/mesa` 并安装这三个子包。
`LOCAL_PKGS` 覆盖整份清单，`ADD_LOCAL_PKGS` 追加条目。

## 依赖

`qemu-user-binfmt`、`python3`、`curl`、`tar`、`gzip`、`sudo`。

## 用法

```sh
make                       # 构建 base 的 rootfs.tar.gz + TWRP 刷机包
make PROFILE=plasma-mobile   # 基础 + Plasma Mobile 桌面层
make profiles              # 列出可用层
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
| `PROFILE` | 叠加的层，空格分隔 | `base` |
| `DESKTOP_USER` / `DESKTOP_PASSWORD` | 桌面层用户 / 密码 | `aries` / `123456` |
| `PACKAGES` / `ADD_PACKAGES` | 替换 / 追加包清单 | 空 |
| `LOCAL_PKGS` / `ADD_LOCAL_PKGS` | 替换 / 追加本地包清单 | 各层 `packages_local.list` |
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
config/profiles/plasma-mobile/   Plasma Mobile 桌面层
packages/<name>/          本地 apk（armv7 chroot + abuild）
scripts/                  构建、打包、recovery 脚本
work/base/rootfs/         rootfs 构建目录
out/                      rootfs tar、刷机包、本地 apk
```

## 内容

- 基础系统：busybox/openrc、WPA supplicant、dropbear、curl/sudo/nano/htop、e2fsprogs/kmod；
  root 密码 `alpine`，时区 `Asia/Shanghai`，主机名 `aries`。
- `/etc/network/interfaces` 只配置回环，满足 dropbear 的 `need net`；WiFi 手工配。
- `buffyboard` 是帧缓冲 tty 的触摸键盘，随 default runlevel 启动；依赖内核 uinput 和 fbdev。
  base 启用 eudev 给触摸屏打 `ID_INPUT_TOUCHSCREEN` 标签，否则 libinput 会判为 unsupported。
- 固件由 initramfs 在切根前拷入，rootfs 不带。
- 本地包 `adbd` 来自 `packages/adbd`：静态、免认证、FunctionFS；服务与 USB 看护脚本同包。
- `plasma-mobile` 层用 `packages/mesa` 的本地构建替换仓库 mesa：只编 armv7 freedreno/a3xx，
  去掉 LLVM/Rusticl/Vulkan/其它 gallium 驱动，并带上 a3xx 崩溃、挂起和渲染修复补丁。
- `plasma-mobile` 层：Plasma Mobile + tinydm autologin + NetworkManager；会禁用 base 的 `buffyboard`
  （它与 kwin_wayland 抢 framebuffer）。用户需加入 `video`/`input`/`audio` 组才能 modeset。

## 刷机包

```
aries-alpine-base-<branch>-<date>.zip
├── rootfs-base.tar.gz                 STORED，第一个成员
└── META-INF/com/google/android/{update-binary,updater-script}
```

TWRP 里选 zip 安装；`update-binary` 是 shell 脚本，按偏移取出 tar 解压到 `/data/rootfs`。
刷机包不含 boot.img（见 [initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）。
