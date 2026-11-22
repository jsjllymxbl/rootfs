# aries rootfs / TWRP 刷机包。用法见 README.md。

SHELL := /bin/bash
.SUFFIXES:
.DEFAULT_GOAL := all

SRC := $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
RUN := sudo -n
# stamp 由 make 用普通用户写，work/ 需保持开发者属主
DEV_UID := $(shell id -u)
DEV_GID := $(shell id -g)

empty :=
space := $(empty) $(empty)

ALPINE_RELEASE ?=
ARCH           ?= armv7
MIRROR         ?= https://dl-cdn.alpinelinux.org/alpine

# 分层：base 永远叠加，PROFILE 里的名字依次叠加
PROFILE        ?= base
PROFILE_LIST   := $(strip $(PROFILE))
EXTRA_PROFILES := $(filter-out base,$(PROFILE_LIST))
PROFILE_SLUG   := $(if $(EXTRA_PROFILES),$(subst $(space),-,$(EXTRA_PROFILES)),base)

CONFIG_DIR   := $(SRC)/config
BASE_DIR     := $(CONFIG_DIR)/base
PROFILE_DIRS := $(foreach p,$(EXTRA_PROFILES),$(CONFIG_DIR)/profiles/$(p))
LAYER_DIRS   := $(BASE_DIR) $(PROFILE_DIRS)
LAYERS       := $(strip base $(EXTRA_PROFILES))

OUT       := $(SRC)/out
WORK_ROOT := $(SRC)/work
WORK      := $(WORK_ROOT)/$(PROFILE_SLUG)

MINIROOTFS := $(WORK_ROOT)/.minirootfs
ROOTFS_DIR := $(WORK)/rootfs
ROOTFS_TAR ?= $(OUT)/rootfs-$(PROFILE_SLUG).tar.gz

APK_BRANCH ?= latest-stable

TARGET_DIR ?= /data/rootfs
DATE       ?= $(shell date +%Y%m%d)
ZIP_NAME   ?= aries-alpine-$(PROFILE_SLUG)-$(APK_BRANCH)-$(DATE).zip
ZIP        ?= $(OUT)/$(ZIP_NAME)

APK_UPGRADE   ?= yes
ROOT_PASSWORD ?= alpine
TIMEZONE      ?= Asia/Shanghai
HOSTNAME      ?= aries
KERNEL_MODULES ?=
APK_CACHE     ?= $(WORK_ROOT)/apkcache
COMPRESS      ?= gzip
SOURCE_DATE_EPOCH ?= 0

# PACKAGES 替换各层清单，ADD_PACKAGES 追加（服务同理）
PACKAGES     ?=
ADD_PACKAGES ?=
SERVICES     ?=
ADD_SERVICES ?=

PKG          ?= adbd
LOCAL_PKGS   ?= adbd
JOBS         ?= 6
PACKAGES_OUT   ?= $(OUT)/packages
PKGBUILD_ROOT  ?= $(WORK_ROOT)/pkgbuild
LOCAL_STAMP    := $(WORK_ROOT)/.local-pkgs

FETCH_MINIROOTFS := $(SRC)/scripts/fetch-minirootfs.sh
BUILD_ROOTFS  := $(SRC)/scripts/build-rootfs.sh
BUILD_PACKAGE := $(SRC)/scripts/build-package.sh
PACK_ZIP      := $(SRC)/scripts/mk-flashable-zip.sh
MKZIP         := $(SRC)/scripts/mkzip.py
UPDATE_BINARY_IN := $(SRC)/scripts/recovery/update-binary.in
UPDATER_SCRIPT   := $(SRC)/scripts/recovery/updater-script

REPOS_FILE := $(BASE_DIR)/repositories

LAYER_FILES := $(shell find $(LAYER_DIRS) -type f 2>/dev/null)
PKG_FILES   := $(shell find $(SRC)/packages -type f 2>/dev/null)

# sudo 会吃掉环境，显式用 env 带过去
define BUILD_ENV
	SRC_DIR='$(SRC)' CONFIG_DIR='$(CONFIG_DIR)' LAYERS='$(LAYERS)' \
	PROFILE='$(PROFILE_SLUG)' WORK_DIR='$(WORK_ROOT)' ROOTFS_DIR='$(ROOTFS_DIR)' \
	OUT_DIR='$(OUT)' TARBALL='$(shell cat $(MINIROOTFS) 2>/dev/null)' \
	REPOS_FILE='$(REPOS_FILE)' APK_BRANCH='$(APK_BRANCH)' \
	APK_UPGRADE='$(APK_UPGRADE)' PACKAGES='$(PACKAGES)' \
	ADD_PACKAGES='$(ADD_PACKAGES)' SERVICES='$(SERVICES)' \
	ADD_SERVICES='$(ADD_SERVICES)' ROOT_PASSWORD='$(ROOT_PASSWORD)' \
	TIMEZONE='$(TIMEZONE)' HOSTNAME='$(HOSTNAME)' \
	KERNEL_MODULES='$(KERNEL_MODULES)' APK_CACHE='$(APK_CACHE)' \
	SOURCE_DATE_EPOCH='$(SOURCE_DATE_EPOCH)' COMPRESS='$(COMPRESS)' \
	ROOTFS_TAR='$(ROOTFS_TAR)' LOCAL_PKGS='$(LOCAL_PKGS)' \
	PACKAGES_OUT='$(PACKAGES_OUT)'
endef

define PACKAGE_ENV
	SRC_DIR='$(SRC)' WORK_DIR='$(WORK_ROOT)' OUT_DIR='$(OUT)' \
	TARBALL='$(shell cat $(MINIROOTFS) 2>/dev/null)' REPOS_FILE='$(REPOS_FILE)' \
	APK_BRANCH='$(APK_BRANCH)' APK_CACHE='$(APK_CACHE)' \
	JOBS='$(JOBS)' PKG_DIR='$(SRC)/packages/$(PKG)' \
	BUILD_ROOT='$(PKGBUILD_ROOT)' OUT_PACKAGES='$(PACKAGES_OUT)'
endef

.PHONY: all fetch package rootfs zip shell check show profiles check-profile \
        ensure-work clean distclean help

all: $(ZIP)

ensure-work:
	@$(RUN) mkdir -p $(WORK_ROOT)
	@$(RUN) chown $(DEV_UID):$(DEV_GID) $(WORK_ROOT)

check-profile:
	@for p in $(EXTRA_PROFILES); do \
		if [ ! -d "$(CONFIG_DIR)/profiles/$$p" ]; then \
			echo "ERROR: 没有 profile '$$p'" >&2; \
			echo "可用: base $(shell ls -1 $(CONFIG_DIR)/profiles 2>/dev/null | tr '\n' ' ')" >&2; \
			exit 1; \
		fi; \
	done

profiles:
	@printf '%-10s %s\n' base '纯基础系统'
	@for d in $(CONFIG_DIR)/profiles/*/; do \
		[ -d "$$d" ] || continue; \
		n=$$(basename "$$d"); \
		desc=$$(head -1 "$$d/packages.list" 2>/dev/null | sed 's/^#[[:space:]]*//'); \
		printf '%-10s %s\n' "$$n" "$${desc:-（无描述）}"; \
	done

show: check-profile
	@printf 'profile : %s\n' '$(PROFILE_LIST)'
	@printf 'layers  : %s\n' '$(LAYERS)'
	@printf 'work    : %s\n' '$(patsubst $(SRC)/%,%,$(ROOTFS_DIR))'
	@printf 'tar     : %s\n' '$(patsubst $(SRC)/%,%,$(ROOTFS_TAR))'
	@printf 'zip     : %s\n' '$(ZIP_NAME)'
	@for f in packages.list services.list; do \
		echo "--- $$f ---"; \
		for l in $(LAYERS); do \
			case $$l in \
				base) d='$(BASE_DIR)' ;; \
				*)    d='$(CONFIG_DIR)/profiles/'$$l ;; \
			esac; \
			[ -f "$$d/$$f" ] || continue; \
			sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' "$$d/$$f" | grep -v '^$$' \
				| sed "s|^|$$l: |"; \
		done | awk '{ k = $$2; if (seen[k]++) { sub(/^[^ ]+ /, "      + "); } print }'; \
	done

FETCH_ENV = ALPINE_RELEASE='$(ALPINE_RELEASE)' ARCH='$(ARCH)' MIRROR='$(MIRROR)'

fetch:
	@$(FETCH_ENV) bash $(FETCH_MINIROOTFS)

$(MINIROOTFS): $(FETCH_MINIROOTFS) | ensure-work
	@$(FETCH_ENV) bash $(FETCH_MINIROOTFS) > $@.tmp
	@mv -f $@.tmp $@

package: $(MINIROOTFS) | check-profile
	$(RUN) env $(PACKAGE_ENV) bash $(BUILD_PACKAGE) $(PKG)

$(LOCAL_STAMP): $(PKG_FILES) $(BUILD_PACKAGE) | ensure-work
	@for p in $(LOCAL_PKGS); do \
		$(MAKE) --no-print-directory package PKG=$$p || exit 1; \
	done
	@rm -f $@ && touch $@

rootfs: $(ROOTFS_TAR)

# 目录本身也是依赖：检测从 overlay 里删掉文件的情形
$(ROOTFS_TAR): $(MINIROOTFS) $(BUILD_ROOTFS) $(SRC)/Makefile $(LAYER_DIRS) $(LAYER_FILES) \
               $(LOCAL_STAMP) | check-profile
	$(RUN) env $(BUILD_ENV) bash $(BUILD_ROOTFS) build

zip: $(ZIP)

$(ZIP): $(ROOTFS_TAR) $(PACK_ZIP) $(MKZIP) $(SRC)/Makefile $(UPDATE_BINARY_IN) $(UPDATER_SCRIPT)
	$(RUN) env SRC_DIR='$(SRC)' WORK_DIR='$(WORK_ROOT)' OUT_DIR='$(OUT)' \
	    ROOTFS_TAR='$(ROOTFS_TAR)' TARGET_DIR='$(TARGET_DIR)' \
	    ZIP_NAME='$(ZIP_NAME)' ZIP='$(ZIP)' \
	    UPDATE_BINARY_IN='$(UPDATE_BINARY_IN)' UPDATER_SCRIPT='$(UPDATER_SCRIPT)' \
	    MKZIP='$(MKZIP)' bash $(PACK_ZIP)

shell: | check-profile
	$(RUN) env $(BUILD_ENV) bash $(BUILD_ROOTFS) shell

check:
	@test -f $(ZIP) || { echo "ERROR: 缺 $(ZIP)，先 make" >&2; exit 1; }
	@unzip -l $(ZIP)
	@for f in update-binary updater-script; do \
		unzip -p $(ZIP) META-INF/com/google/android/$$f | grep -q '@@' \
			&& { echo "ERROR: $$f 占位没替换" >&2; exit 1; } \
			|| echo "==> $$f 占位已替换"; \
	done

clean:
	@for d in $(WORK_ROOT)/*/rootfs $(WORK_ROOT)/rootfs; do \
		[ -d "$$d" ] || continue; \
		$(RUN) env ROOTFS_DIR="$$d" bash $(BUILD_ROOTFS) umount || exit 1; \
	done
	$(RUN) env BUILD_ROOT='$(PKGBUILD_ROOT)' bash $(BUILD_PACKAGE) umount
	$(RUN) rm -rf $(WORK_ROOT) $(OUT)

distclean: clean
	rm -f $(SRC)/alpine-minirootfs-*.tar.gz

help:
	@echo '用法: make [目标] [变量=值 ...]；详见 README.md'
	@echo '目标: all profiles show package fetch rootfs zip shell check clean distclean'
	@echo '常用变量: PROFILE PACKAGES ADD_PACKAGES SERVICES ADD_SERVICES ROOT_PASSWORD'
	@echo '          KERNEL_MODULES APK_BRANCH ALPINE_RELEASE TARGET_DIR COMPRESS'
