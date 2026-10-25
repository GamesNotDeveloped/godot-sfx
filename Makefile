SHELL:=/bin/bash
.PHONY: compile-debug compile-release compile-release-linux compile-windows-debug compile-windows-release \
	compile-android-debug compile-android-release \
	check-glibc linux-sdk-image import test docs
.DEFAULT_GOAL = compile-debug

# single for a stock Godot, double for a double precision one (Rails Reloaded's godot-double): a
# GDExtension loads only into an engine of its own precision. Each lands under its own name
# (libgndsfx.gdextension picks it by the "double" feature tag)
PRECISION?=single
GODOT?=$(if $(filter double,$(PRECISION)),godot-double,godot)
API_VERSION=4.7
JOBS=$(shell cores=$$(nproc 2>/dev/null || echo 1); if [ "$$cores" -gt 2 ]; then echo $$((cores - 2)); else echo 1; fi)
# godot-cpp ships the single precision API only: the double one is dumped from $(GODOT) (on the
# host - the SDK container has no Godot) and not versioned; delete it after an engine update
DOUBLE_API_FILE=$(CURDIR)/extension_api.double.json
API_FILE=$(if $(filter double,$(PRECISION)),$(DOUBLE_API_FILE))
CMAKE_ARGS=-DGODOTCPP_PRECISION=$(PRECISION) -DGODOTCPP_API_VERSION=$(API_VERSION) $(if $(API_FILE),-DGODOTCPP_CUSTOM_API_FILE=$(API_FILE))
MINGW_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
	-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ -DCMAKE_SIZEOF_VOID_P=8 -DCMAKE_SYSTEM_PROCESSOR=x86_64
# The debug library is what the editor and a game run from it load: optimized like the engine's own
# template_debug, with symbols; BUILD_TYPE=Debug for stepping through it
BUILD_TYPE?=RelWithDebInfo
# configure + build of one flavour: $(call build,<dir>,<build type>,<godot-cpp target>,<extra args>)
build=cmake -B $(1)-$(PRECISION) $(CMAKE_ARGS) -DCMAKE_BUILD_TYPE=$(2) -DGODOTCPP_TARGET=$(3) $(4) \
	&& cmake --build $(1)-$(PRECISION) --parallel $(JOBS)

compile-debug: $(API_FILE)
	$(call build,build-debug,$(BUILD_TYPE),template_debug)

compile-release: $(API_FILE)
	$(call build,build-release,Release,template_release)

compile-windows-debug: $(API_FILE)
	$(call build,build-win64-debug,$(BUILD_TYPE),template_debug,$(MINGW_ARGS))

compile-windows-release: $(API_FILE)
	$(call build,build-win64-release,Release,template_release,$(MINGW_ARGS))

# arm64 with the NDK's own toolchain file: any NDK will do for a GDExtension, GitHub's runners carry
# one in ANDROID_NDK_LATEST_HOME. API level 24 is the lowest Godot's Android export supports
ANDROID_NDK_ROOT?=$(ANDROID_NDK_LATEST_HOME)
ANDROID_API?=24
ANDROID_ARGS=-DCMAKE_TOOLCHAIN_FILE=$(ANDROID_NDK_ROOT)/build/cmake/android.toolchain.cmake \
	-DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=$(ANDROID_API)

compile-android-debug: $(API_FILE)
	@test -d "$(ANDROID_NDK_ROOT)" || { echo "No NDK: make $@ ANDROID_NDK_ROOT=<path>" >&2; exit 1; }
	$(call build,build-android-debug,$(BUILD_TYPE),template_debug,$(ANDROID_ARGS))

compile-android-release: $(API_FILE)
	@test -d "$(ANDROID_NDK_ROOT)" || { echo "No NDK: make $@ ANDROID_NDK_ROOT=<path>" >&2; exit 1; }
	$(call build,build-android-release,Release,template_release,$(ANDROID_ARGS))

# glibc is only forward compatible: a library linked against a rolling distribution's glibc refuses
# to load on anything older. The Linux release is built in ci/docker/linux-sdk - libreloaded's own
# Dockerfile, byte for byte, so it is the same image (Godot's buildroot SDK, glibc 2.34) under the
# same tag: pulled from ghcr.io when there, built locally otherwise
LINUX_SDK_IMAGE:=ghcr.io/maszyna-reloaded/linux-sdk:$(shell sha256sum ci/docker/linux-sdk/Dockerfile | cut -c1-12)
CCACHE_DIR?=$(HOME)/.cache/ccache
GLIBC_MAX=2.34

linux-sdk-image:
	docker image inspect $(LINUX_SDK_IMAGE) > /dev/null 2>&1 || docker pull -q $(LINUX_SDK_IMAGE) \
		|| docker build -q -t $(LINUX_SDK_IMAGE) ci/docker/linux-sdk

compile-release-linux: linux-sdk-image $(API_FILE)
	mkdir -p $(CCACHE_DIR) && docker run --rm --user $(shell id -u):$(shell id -g) -v $(CURDIR):$(CURDIR) -w $(CURDIR) \
		-v $(CCACHE_DIR):/ccache -e CCACHE_DIR=/ccache -e CMAKE_CXX_COMPILER_LAUNCHER=ccache $(LINUX_SDK_IMAGE) \
		sh -c '$(call build,build-release-linux,Release,template_release)'
	$(MAKE) check-glibc

# Fails when a Linux library needs a newer glibc than GLIBC_MAX
check-glibc:
	@for lib in addons/gnd_sfx/bin/linux/libgndsfx*template_release*.so; do \
		need=$$(objdump -T $$lib | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -Vu | tail -1); \
		echo "$$lib: GLIBC_$$need"; \
		[ "$$(printf '%s\n%s\n' $$need $(GLIBC_MAX) | sort -V | tail -1)" = "$(GLIBC_MAX)" ] || { echo "needs glibc > $(GLIBC_MAX)" >&2; exit 1; }; \
	done

$(DOUBLE_API_FILE):
	mkdir -p build-api && cd build-api && $(GODOT) --headless --dump-extension-api
	grep -q '"precision": "double"' build-api/extension_api.json || { echo "$(GODOT) is not a double precision Godot" >&2; exit 1; }
	mv build-api/extension_api.json $@

import:
	timeout 120 $(GODOT) --headless --path demo --import

# GUT skips a test script that does not parse with only a warning, so the run also fails on the
# engine's own message for it
test:
	set -o pipefail; timeout 300 $(GODOT) --headless --path demo -s res://addons/gut/gut_cmdln.gd -gexit 2>&1 | tee gut.log
	! grep -q "Failed to load script" gut.log

# Refreshes doc_classes/*.xml from the built library (new members get empty descriptions)
docs:
	cd demo && $(GODOT) --headless --doctool .. --gdextension-docs
