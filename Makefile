# ZiYan — rootful (默认) / rootless 双方案
# rootless 交付（USB arm64 机）：make package-rootless
# rootful 旧机：make package   或  make package THEOS_PACKAGE_SCHEME=

TARGET := iphone:clang:latest:13.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = SpringBoard ZiYan

# 勿默认连局域网其它手机；USB 验收用 iproxy→127.0.0.1
# THEOS_DEVICE_IP =
# THEOS_DEVICE_PORT = 22

# rootless：须在 include common.mk 之前设置（可通过命令行覆盖）
# make package-rootless 会导出 THEOS_PACKAGE_SCHEME=rootless

include $(THEOS)/makefiles/common.mk

# 勿用 PREFIX 名（易与 Theos/环境冲突）。rootless 下 Theos 已把组件装到
# $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/…；after-stage 必须写到同一根，
# 且在 recipe 内展开，避免 parse 期与 stage 期 STAGING 不一致导致 /var/jb/var/jb。
ZIYAN_JB := $(THEOS_PACKAGE_INSTALL_PREFIX)

APPLICATION_NAME = ZiYan
# 8-161-62：ZiYanBBTouch（HID）仍不编入——曾触发重启环。
# 137：ZiYanBBFrame（仅合帧）编入 backboardd；须 .ziyan_bbframe_on 才轮询。
TWEAK_NAME = ZiYanVol ZiYanFrameRelay ZiYanAppTouch ZiYanDefense ZiYanFsCloak ZiYanBBFrame

SHARED = objc/shared/ZiYanScriptRunner.m objc/shared/ZiYanEngine.m \
	objc/shared/ZiYanControlShm.m \
	objc/shared/ZiYanHIDOptimizer.m \
	objc/shared/ZiYanFrameTrace.m
INC = -Iobjc/shared -Iobjc/tweak/springboard -Iobjc/tweak/apptouch -Iobjc/tweak/defense -Iobjc/tweak/fscloak -Iobjc/app

ZiYan_FILES = \
	objc/app/main.m \
	objc/app/ceshiAppDelegate.m \
	objc/app/ceshiRootViewController.m \
	objc/app/ZiYanAppSelector.m \
	objc/app/ZiYanLLMSidecarClient.m \
	objc/app/ZiYanScriptGenerator.m \
	objc/app/ZiYanLiveVisionLearn.m \
	objc/app/ZiYanDumpManager.m \
	objc/app/VolumeKeyMonitor.m \
	objc/app/OverlayWindow.m \
	objc/app/ZiYanAppKeepAlive.m \
	objc/app/ZiYanAppBridgeShm.m \
	objc/shared/ZiYanScriptRecorder.m \
	objc/shared/ZiYanFrameShm.m \
	$(SHARED)
ZiYan_FRAMEWORKS = UIKit CoreGraphics Vision AVFoundation MediaPlayer CoreLocation
ZiYan_CFLAGS = -fobjc-arc $(INC)
ZiYan_CODESIGN_FLAGS = -Sobjc/app/entitlements.plist

ZiYanVol_FILES = \
	objc/tweak/springboard/Tweak.m \
	objc/tweak/springboard/ZiYanToastBridge.m \
	objc/tweak/springboard/ZiYanScreenBridge.m \
	objc/tweak/springboard/ZiYanBootRecovery_stub.m \
	objc/tweak/springboard/ZiyanProcessWatchdog_stub.m \
	objc/tweak/springboard/ZiYanSbRestartStats_stub.m \
	objc/tweak/springboard/ZiYanIconShield.m \
	objc/tweak/springboard/ZiYanUnifiedDispatcher.m \
	objc/tweak/springboard/ZiYanMinimalBridge.m \
	objc/tweak/springboard/ZiYanFrameHook.m \
	objc/shared/ZiYanFrameShm.m \
	objc/shared/ZiYanFrameCapture.m \
	objc/shared/ZiYanScriptRecorder.m \
	$(SHARED)
# 8-158 / T6 Step7：BootRecovery+Watchdog+Stats → stub；保留 ScreenBridge/Toast/Icon/Tweak（硬锁）
# 完整 BootRecovery.m 仍留作对照，默认不编进 ZiYanVol
ZiYanVol_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) -DZIYAN_DAEMON_V2=1 -DZIYAN_T6_STEP7=1
ZiYanVol_FRAMEWORKS = UIKit Foundation CoreFoundation MediaPlayer AVFoundation IOKit CoreGraphics QuartzCore Vision ImageIO IOSurface
# NOTE: ZiYanVol_CFLAGS 已上移；勿重复定义
ZiYanVol_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

ZiYanVol_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib -weak_framework IOSurface

# 8-159：全零时用极薄合帧中继替代 ZiYanVol（仅 ScreenBridge；音量/图标不在此）
ZiYanFrameRelay_FILES = \
	objc/tweak/framerelay/Tweak.m \
	objc/tweak/framerelay/ZiYanToastBridge_stub.m \
	objc/tweak/springboard/ZiYanScreenBridge.m \
	objc/tweak/springboard/ZiYanBootRecovery_stub.m \
	objc/tweak/springboard/ZiyanProcessWatchdog_stub.m \
	objc/tweak/springboard/ZiYanSbRestartStats_stub.m \
	objc/shared/ZiYanFrameShm.m \
	objc/shared/ZiYanFrameCapture.m \
	objc/shared/ZiYanScriptRecorder.m \
	$(SHARED)
ZiYanFrameRelay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) -DZIYAN_DAEMON_V2=1 -DZIYAN_FRAME_RELAY_ONLY=1
ZiYanFrameRelay_FRAMEWORKS = UIKit Foundation CoreFoundation IOKit CoreGraphics QuartzCore Vision ImageIO IOSurface
ZiYanFrameRelay_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ZiYanFrameRelay_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.dylib -weak_framework IOSurface

ZiYanAppTouch_FILES = \
	objc/tweak/apptouch/ZiYanAppTouch.m \
	objc/tweak/apptouch/ZiYanMemHook.m \
	objc/shared/ZiYanScriptRecorder.m
ZiYanAppTouch_FRAMEWORKS = Foundation UIKit IOKit
ZiYanAppTouch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC)
ZiYanAppTouch_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# 临摹 TSEventTweak：全局 HID，桌面/未注入游戏时也能消费 touch_req（禁抢 AppTouch）
ZiYanBBTouch_FILES = \
	objc/tweak/bbtouch/Tweak.m \
	objc/shared/ZiYanTouchBridge.m
ZiYanBBTouch_FRAMEWORKS = Foundation IOKit
ZiYanBBTouch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC)
ZiYanBBTouch_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ZiYanBBTouch_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanBBTouch.dylib

# 137：backboardd 全局合帧（IOMFB/CARender→shm）；无 HID
ZiYanBBFrame_FILES = \
	objc/tweak/bbframe/Tweak.m \
	objc/shared/ZiYanFrameCapture.m \
	objc/shared/ZiYanFrameShm.m
ZiYanBBFrame_FRAMEWORKS = Foundation CoreFoundation CoreGraphics IOKit QuartzCore IOSurface UIKit
ZiYanBBFrame_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC)
ZiYanBBFrame_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ZiYanBBFrame_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanBBFrame.dylib -weak_framework IOSurface -weak_framework UIKit

ZiYanDefense_FILES = \
	objc/tweak/defense/ZiYanDefense.m \
	objc/tweak/defense/ZiYanDefenseAI.m
ZiYanDefense_FRAMEWORKS = Foundation UIKit
ZiYanDefense_LIBRARIES = substrate
ZiYanDefense_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC)
ZiYanDefense_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# USB/AFC 越狱路径伪装（爱思等）；仅 afcd/afc2d
ZiYanFsCloak_FILES = objc/tweak/fscloak/ZiYanFsCloak.m
ZiYanFsCloak_FRAMEWORKS = Foundation
ZiYanFsCloak_LIBRARIES = substrate
ZiYanFsCloak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC)
ZiYanFsCloak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = ziyan_ocr ziyan_mem ziyan_framecap ziyan_scriptgen_smoke ziyanctl ziyadaemond ziyan_shm_selftest
ziyan_ocr_FILES = tools/ziyan_ocr/main.m
ziyan_ocr_FRAMEWORKS = Foundation UIKit Vision CoreGraphics ImageIO CoreImage
ziyan_ocr_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ziyan_ocr_INSTALL_PATH = /usr/lib/ziyan/bin

ziyan_mem_FILES = tools/ziyan_mem/main.m
ziyan_mem_FRAMEWORKS = Foundation
ziyan_mem_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ziyan_mem_CODESIGN_FLAGS = -Stools/ziyan_mem/entitlements.plist
ziyan_mem_INSTALL_PATH = /usr/lib/ziyan/bin

ziyan_framecap_FILES = \
	tools/ziyan_framecap/main.m \
	tools/ziyan_framecap/ZiYanLuaEmbed.m \
	tools/ziyan_framecap/ZiYanSnapshotHttp.m \
	tools/ziyan_framecap/ziyan_ios_system.c \
	objc/shared/ZiYanFrameCapture.m \
	objc/shared/ZiYanFrameShm.m \
	objc/shared/ZiYanFrameResident.m \
	objc/shared/ZiYanFrameKeep.m \
	objc/shared/ZiYanFrameTrace.m \
	objc/shared/ZiYanControlShm.m \
	objc/shared/ZiYanColorMatch.m \
	objc/shared/ZiYanHIDOptimizer.m \
	tools/ziyan_ncnn_findcolor/ZiYanNcnnInference.m \
	tools/ziyan_ncnn_findcolor/ZiYanNcnnMatch.m \
	tools/ziyan_ncnn_findcolor/ziyan_ncnn_bridge.cpp \
	vendor/lua-5.3.5/src/lapi.c \
	vendor/lua-5.3.5/src/lauxlib.c \
	vendor/lua-5.3.5/src/lbaselib.c \
	vendor/lua-5.3.5/src/lbitlib.c \
	vendor/lua-5.3.5/src/lcode.c \
	vendor/lua-5.3.5/src/lcorolib.c \
	vendor/lua-5.3.5/src/lctype.c \
	vendor/lua-5.3.5/src/ldblib.c \
	vendor/lua-5.3.5/src/ldebug.c \
	vendor/lua-5.3.5/src/ldo.c \
	vendor/lua-5.3.5/src/ldump.c \
	vendor/lua-5.3.5/src/lfunc.c \
	vendor/lua-5.3.5/src/lgc.c \
	vendor/lua-5.3.5/src/linit.c \
	vendor/lua-5.3.5/src/liolib.c \
	vendor/lua-5.3.5/src/llex.c \
	vendor/lua-5.3.5/src/lmathlib.c \
	vendor/lua-5.3.5/src/lmem.c \
	vendor/lua-5.3.5/src/loadlib.c \
	vendor/lua-5.3.5/src/lobject.c \
	vendor/lua-5.3.5/src/lopcodes.c \
	vendor/lua-5.3.5/src/loslib.c \
	vendor/lua-5.3.5/src/lparser.c \
	vendor/lua-5.3.5/src/lstate.c \
	vendor/lua-5.3.5/src/lstring.c \
	vendor/lua-5.3.5/src/lstrlib.c \
	vendor/lua-5.3.5/src/ltable.c \
	vendor/lua-5.3.5/src/ltablib.c \
	vendor/lua-5.3.5/src/ltm.c \
	vendor/lua-5.3.5/src/lundump.c \
	vendor/lua-5.3.5/src/lutf8lib.c \
	vendor/lua-5.3.5/src/lvm.c \
	vendor/lua-5.3.5/src/lzio.c
ziyan_framecap_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore IOSurface ImageIO
# 8-148：BSD-3 Tencent/ncnn（vendor/ncnn-ios，禁 Vulkan/ANE）；C++ bridge 无 modules
# 8-161-57：Lua 5.3.5 静态链进 framecap（禁 dylib：rootless 绝对路径/改 install_name 毁签）
ziyan_framecap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared \
	-Itools/ziyan_ncnn_findcolor -Ivendor/lua-5.3.5/src -fvisibility=hidden \
	-DLUA_COMPAT_5_2 -Wno-string-plus-int -Wno-unused-parameter
ziyan_framecap_CCFLAGS = -std=c++14 -fno-modules -fvisibility=hidden \
	-Ivendor/ncnn-ios/ncnn.framework/Headers \
	-Itools/ziyan_ncnn_findcolor
ziyan_framecap_CODESIGN_FLAGS = -Stools/ziyan_framecap/entitlements.plist
ziyan_framecap_INSTALL_PATH = /usr/lib/ziyan/bin
# IOSurface 符号运行时 dlsym；弱链避免老 SDK 链接失败
# ncnn/openmp 为静态 ar（LICENSE arm64）；链进 framecap，无需设备侧 Frameworks
ziyan_framecap_LDFLAGS = -weak_framework IOSurface -weak_framework QuartzCore \
	-Fvendor/ncnn-ios -framework ncnn -framework openmp -lc++

# 阶段2：FrameShm 防半帧 / v1 兼容本地自检（可 host 跑 tools/ziyan_shm_selftest/run_host.sh）
ziyan_shm_selftest_FILES = \
	tools/ziyan_shm_selftest/main.m \
	objc/shared/ZiYanFrameShm.m
ziyan_shm_selftest_FRAMEWORKS = Foundation
ziyan_shm_selftest_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared
ziyan_shm_selftest_INSTALL_PATH = /usr/lib/ziyan/bin

# 脚本生成/脱壳后端冒烟（.101 无可靠 UI 启动时用 CLI 验收）
ziyan_scriptgen_smoke_FILES = \
	tools/ziyan_scriptgen_smoke/main.m \
	objc/app/ZiYanAppSelector.m \
	objc/app/ZiYanLLMSidecarClient.m \
	objc/app/ZiYanScriptGenerator.m \
	objc/app/ZiYanLiveVisionLearn.m \
	objc/app/ZiYanDumpManager.m
ziyan_scriptgen_smoke_FRAMEWORKS = Foundation UIKit Vision
ziyan_scriptgen_smoke_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared -Iobjc/app
ziyan_scriptgen_smoke_CODESIGN_FLAGS = -Stools/ziyan_mem/entitlements.plist
ziyan_scriptgen_smoke_INSTALL_PATH = /usr/lib/ziyan/bin

# 8-150：ControlShm CLI（Lua/daemon 双写与心跳）
ziyanctl_FILES = tools/ziyanctl/main.m objc/shared/ZiYanControlShm.m
ziyanctl_FRAMEWORKS = Foundation
ziyanctl_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared
ziyanctl_INSTALL_PATH = /usr/lib/ziyan/bin

# T5：ObjC zydaemon（Icon/Boot/Stats/Watchdog 决策层）
ziyadaemond_FILES = \
	tools/ziyadaemond/main.m \
	tools/ziyadaemond/ZiYanIconShieldDaemon.m \
	tools/ziyadaemond/ZiYanBootRecoveryDaemon.m \
	tools/ziyadaemond/ZiYanSbRestartStatsDaemon.m \
	tools/ziyadaemond/ZiYanWatchdogDaemon.m \
	objc/shared/ZiYanControlShm.m
ziyadaemond_FRAMEWORKS = Foundation
ziyadaemond_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared -Itools/ziyadaemond
ziyadaemond_INSTALL_PATH = /usr/lib/ziyan/bin

include $(THEOS_MAKE_PATH)/tool.mk

.PHONY: stage-runtime package-rootless package-rootful clean-user-bins

# 用户手动导入的可执行测试文件（Mach-O / .bin / .exe），每次 make 清空；不动 vendor/.theos
clean-user-bins:
	@echo "[ZiYan] clean user-imported executables (keep vendor/ .theos/ packages/)"
	@rm -f "$(CURDIR)"/*.bin "$(CURDIR)"/*.exe \
		"$(CURDIR)"/lua5.3 "$(CURDIR)"/lua "$(CURDIR)"/python3 "$(CURDIR)"/python3.7 \
		"$(CURDIR)"/ziyan_ocr "$(CURDIR)"/ziyan_mem "$(CURDIR)"/wnriakwyww \
		"$(CURDIR)"/TSDaemon "$(CURDIR)"/Hades "$(CURDIR)"/TouchSprite 2>/dev/null || true
	@# 清空 layout 下用户可执行脚本（手动导入测试用；seed 走 media_seed/）
	@if [ -d "$(CURDIR)/layout/private/var/mobile/Media/ZiYan" ]; then \
		echo "[ZiYan] clean layout Media/ZiYan scripts"; \
		find "$(CURDIR)/layout/private/var/mobile/Media/ZiYan" -type f \
			\( -name '*.lua' -o -name '*.luac' -o -name '*.bin' -o -name '*.exe' \) \
			! -name 'README.txt' -print -delete 2>/dev/null || true; \
	fi
	@if [ -d "$(CURDIR)/tmp_shots" ]; then \
		find "$(CURDIR)/tmp_shots" -type f \( -name '*.bin' -o -name '*.exe' \
			-o -name 'TSDaemon*' -o -name 'Hades' -o -name 'wnriakwyww' \
			-o -name 'lua5.3' -o -name 'ziyan_ocr' -o -name 'ziyan_mem' \) \
			-print -delete 2>/dev/null || true; \
	fi
	@find "$(CURDIR)" -maxdepth 3 -type f \( -name '*.bin' -o -name '*.exe' \
		-o -name 'TSDaemon' -o -name 'Hades' -o -name 'wnriakwyww' \
		-o -name 'lua5.3' -o -name 'ziyan_ocr' -o -name 'ziyan_mem' \) \
		! -path '*/.theos/*' ! -path '*/vendor/*' ! -path '*/.git/*' \
		! -path '*/packages/*' ! -path '*/layout/*' \
		-print -delete 2>/dev/null || true
	@find "$(CURDIR)" -maxdepth 2 -type f -perm +111 \
		! -path '*/.theos/*' ! -path '*/vendor/*' ! -path '*/.git/*' \
		! -path '*/packages/*' ! -path '*/layout/*' ! -path '*/tools/*' \
		! -name '*.sh' ! -name '*.py' ! -name '*.lua' \
		-exec sh -c 'file "$$1" | grep -qE "Mach-O|PE32|ELF" && rm -f "$$1" && echo "  rm $$1"' _ {} \; \
		2>/dev/null || true

before-all:: clean-user-bins

clean:: clean-user-bins

# DEST = staging 根（已含 /var/jb）；JB = 设备上绝对前缀（用于 symlink/plist）
# rootless：after-stage 必须写到「未加 /var/jb」的经典路径（$STAGING/usr/...）。
# Theos/dm.pl 会再 remap 一次到 $STAGING/var/jb/...；若这里已写 /var/jb 会变成 var/jb/var/jb。
# 绝对 symlink（/var/jb/...）与 plist 内 jb 前缀也勿在 staging 写入；postinst 在真机补齐。
stage-runtime:
	@DEST="$(THEOS_STAGING_DIR)"; \
	mkdir -p "$$DEST/usr/lib/ziyan/bin" \
		"$$DEST/usr/lib/ziyan/lib/lua" \
		"$$DEST/usr/lib/ziyan/engine" \
		"$$DEST/usr/lib/ziyan/runtime" \
		"$$DEST/usr/lib/ziyan/hook" \
		"$$DEST/usr/lib/ziyan/var" \
		"$$DEST/usr/lib/ziyan/modules" \
		"$$DEST/usr/lib/ziyan/models" \
		"$$DEST/Library/LaunchDaemons" \
		"$$DEST/usr/lib/ziyan/share/media_seed"; \
	rsync -a vendor/bin/ "$$DEST/usr/lib/ziyan/bin/"; \
	rsync -a --exclude='lua' vendor/lib/ "$$DEST/usr/lib/ziyan/lib/"; \
	rsync -a --delete lua/ "$$DEST/usr/lib/ziyan/lib/lua/"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/lua5.3" \
		"$$DEST/usr/lib/ziyan/bin/python3.7" 2>/dev/null || true; \
	ln -sfn lua5.3 "$$DEST/usr/lib/ziyan/bin/lua"; \
	ln -sfn python3.7 "$$DEST/usr/lib/ziyan/bin/python3"; \
	ln -sfn libreadline.8.0.dylib "$$DEST/usr/lib/ziyan/lib/libreadline.8.dylib"; \
	cp -f vendor/runtime/engine/wnriakwyww "$$DEST/usr/lib/ziyan/engine/wnriakwyww"; \
	cp -f vendor/runtime/engine/wnriakwyww.dylib "$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
	chmod 755 "$$DEST/usr/lib/ziyan/engine/wnriakwyww" \
		"$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
	rsync -a --delete vendor/runtime/data/ "$$DEST/usr/lib/ziyan/runtime/"; \
	mkdir -p "$$DEST/usr/lib/ziyan/runtime/scripts" \
		"$$DEST/usr/lib/ziyan/runtime/var/log" \
		"$$DEST/usr/lib/ziyan/runtime/var/tmp"; \
	cp -f vendor/runtime/hook/ZiYanTEHook.dylib "$$DEST/usr/lib/ziyan/hook/"; \
	cp -f vendor/runtime/hook/ZiYanTEHook.plist "$$DEST/usr/lib/ziyan/hook/"; \
	rsync -a --delete vendor/modules/ "$$DEST/usr/lib/ziyan/modules/"; \
	rsync -a layout/usr/lib/ziyan/models/ "$$DEST/usr/lib/ziyan/models/" 2>/dev/null || true; \
	cp -f vendor/runtime/launch/com.ziyan.engine.plist \
		"$$DEST/Library/LaunchDaemons/com.ziyan.engine.plist"; \
	cp -f vendor/runtime/launch/com.ziyan.fscloak.plist \
		"$$DEST/Library/LaunchDaemons/com.ziyan.fscloak.plist"; \
	cp -f vendor/runtime/bin/ziyan_fscloakd.sh \
		"$$DEST/usr/lib/ziyan/bin/ziyan_fscloakd.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_fscloakd.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_zero_sb_unload.sh" 2>/dev/null || true; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_framerelay_toggle.sh" 2>/dev/null || true; \
	cp -f vendor/runtime/launch/com.ziyan.scripthub.plist \
		"$$DEST/Library/LaunchDaemons/com.ziyan.scripthub.plist"; \
	cp -f vendor/runtime/bin/ziyan_scripthubd.sh \
		"$$DEST/usr/lib/ziyan/bin/ziyan_scripthubd.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_scripthubd.sh"; \
	cp -f vendor/runtime/launch/com.ziyan.zydaemon.plist \
		"$$DEST/Library/LaunchDaemons/com.ziyan.zydaemon.plist"; \
	cp -f vendor/runtime/bin/ziyan_zydaemond.sh \
		"$$DEST/usr/lib/ziyan/bin/ziyan_zydaemond.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_zydaemond.sh"; \
	cp -f vendor/runtime/bin/ziyan_framecap_wrap.sh \
		"$$DEST/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh"; \
	cp -f vendor/runtime/launch/com.ziyan.framecap.plist \
		"$$DEST/Library/LaunchDaemons/com.ziyan.framecap.plist"; \
	rsync -a layout/private/var/mobile/Media/ZiYan/ \
		"$$DEST/usr/lib/ziyan/share/media_seed/" 2>/dev/null || true; \
	rsync -a media_seed/ \
		"$$DEST/usr/lib/ziyan/share/media_seed/" 2>/dev/null || true; \
	# layout 不再直装 login_*；仅 media_seed + postinst cp -n
	rm -f "$$DEST/private/var/mobile/Media/ZiYan/login_xztl.lua" \
		"$$DEST/private/var/mobile/Media/ZiYan/login_lan.lua" \
		"$$DEST/private/var/mobile/Media/ZiYan/login_usb.lua" 2>/dev/null || true; \
	echo "[ZiYan] staged (pre-remap) → $$DEST/usr/lib/ziyan scheme=$(THEOS_PACKAGE_SCHEME)"

after-stage:: stage-runtime

# 8-161-74：一次 make 打双包（rootful arm + rootless arm64），兼容 iPhone7/8Plus
# 用法：make   或  make dual-package
# （勿用 Theos 自带 packages 名；勿再分两次手敲 rootful/rootless）
.PHONY: dual-package package-rootless package-rootful inject-gate-53
.DEFAULT_GOAL := dual-package

dual-package:
	@bash tools/zy_dual_package.sh

# 旧目标名统一走双包，避免机型/scheme 装错
package-rootless package-rootful: dual-package

inject-gate-53:
	bash tools/device_inject_gate.sh 192.168.31.53 rootless
