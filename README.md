# aries rootfs / TWRP 刷机包

小米 2（aries，APQ8064）主线 Linux 的 Alpine rootfs 与 TWRP 刷机包。

```
bootloader -> lk2nd -> boot.img（[initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）-> /init 挂 userdata(p23)
  -> switch_root 到 <userdata>/rootfs -> /sbin/init
```

## 配置结构

每层可选六个部分：

| 文件 | 作用 |
| --- | --- |
| `packages.list` | 从 Alpine 仓库安装的包（第一行注释当作层描述） |
| `packages_local.list` | 本地包（格式 `配方:包1,包2,...`，见下） |
| `services.list` | `<服务>[:<runlevel>]`，默认 `default` |
| `overlay/` | 直接覆盖到 rootfs 的文件树 |
| `post-install.sh` | chroot 内执行一次（可用 `LAYER`/`PROFILE`/`DESKTOP_USER`/`DESKTOP_PASSWORD`/`LAYER_LIB`） |
| `requires` | 必须前置的层，每行一个 |

分层规则：

- `config/base` 永远最先叠。
- `config/profiles/<name>` 按 `PROFILE` 叠加；`requires` 里点名的层自动排在前面，不用手工拼。
  `make PROFILE=phosh` 等价于 `PROFILE="desktop phosh"`。
- 包/服务取并集去重，overlay 后叠覆盖先叠。

现有层：

| 层 | 内容 |
| --- | --- |
| `base` | 纯基础系统；设备相关配置也在这里 |
| `desktop` | 共用桌面层：会话总线、网络、自动登录、图形驱动、中文环境、普通用户 |
| `phosh` | Phosh 桌面层（requires `desktop`） |
| `plasma-mobile` | Plasma Mobile 桌面层（requires `desktop`） |

`post-install.sh` 里的建用户/加组/sudo/家目录/关 fb 键盘/设会话都走
`config/lib/hooks.sh`（构建脚本装进 chroot，用 `LAYER_LIB` 传给钩子）。桌面层通常只需要：

```sh
. "${LAYER_LIB:?}"
hook_session phosh.desktop   # /usr/share/wayland-sessions 下的文件名
```

`packages_local.list` 的每行是 `配方:包1,包2,...`（或只写配方名）：配方对应
`packages/<配方>/`，里面可以放 `APKBUILD` 源码构建，也可以直接放 `*.apk` 预编译包。
冒号后的包才装进 rootfs。例如 `mesa:mesa,mesa-dri-gallium,mesa-egl` 使用
`packages/mesa` 并安装这三个子包。`LOCAL_PKGS` 覆盖整份清单，`ADD_LOCAL_PKGS` 追加条目。
预编译包按显式 apk 文件安装，因此即使版本号低于仓库也能替换同名包。

## 依赖

`qemu-user-binfmt`、`python3`、`curl`、`tar`、`gzip`、`sudo`。

## 用法

```sh
make                        # 构建 base 的 rootfs.tar.gz + TWRP 刷机包
make PROFILE=phosh          # 基础 + 共用桌面层 + Phosh
make PROFILE=plasma-mobile  # 基础 + 共用桌面层 + Plasma Mobile
make profiles               # 列出可用层（含 requires）
make show                   # 查看展开后的层、包/服务与产物名
make package PKG=adbd       # 单独编本地包（out/packages/）
make fetch                  # 下载 minirootfs
make rootfs / make zip      # 只构建 rootfs / 只打刷机包
make shell                  # 进 chroot
make check                  # 校验刷机包
make clean / distclean      # 卸载挂载后删除 work/ 和 out/
```

常用变量：

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `PROFILE` | 要叠加的层，空格分隔（依赖会自动展开） | `base` |
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
config/base/                    基础层（含设备相关的 overlay）
config/profiles/desktop/        共用桌面层
config/profiles/phosh/          Phosh 桌面层
config/profiles/plasma-mobile/  Plasma Mobile 桌面层
config/lib/hooks.sh             post-install 共用函数
packages/<name>/                本地 apk（armv7 chroot + abuild）
scripts/                        构建、打包、层解析、recovery 脚本
work/<层组合>/rootfs/           rootfs 构建目录
out/                            rootfs tar、刷机包、本地 apk
```


## 刷机包

```
aries-alpine-<层组合>-<branch>-<date>.zip
├── rootfs-<层组合>.tar.gz             STORED，第一个成员
└── META-INF/com/google/android/{update-binary,updater-script}
```

TWRP 里选 zip 安装；`update-binary` 是 shell 脚本，按偏移取出 tar 解压到 `/data/rootfs`。
刷机包不含 boot.img（见 [initramfs 仓库](https://github.com/jsjllymxbl/initramfs)）。
