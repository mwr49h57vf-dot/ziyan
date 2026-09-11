# ZiYan — rootful (默认) / rootless 双方案
# rootless 交付（USB arm64 机）：make package-rootless
# rootful 旧机：make package   或  make package THEOS_PACKAGE_SCHEME=

TARGET := iphone:clang:latest:13.0
ARCHS := arm64
# Theos `make install` used to kill these processes. That is an automatic
# SpringBoard restart and is forbidden. Leave empty; inject reload is a
# separate human-authorized step.
INSTALL_TARGET_PROCESSES =

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
# 8-161-62：ZiYanBBTouch 默认零副作用；只有 .ziyan_bbtouch_enable 存在时
# 才在 backboardd 建立 HID 轮询，行为对齐 TouchSprite 的 TSEventTweak。
# 137：ZiYanBBFrame（仅合帧）编入 backboardd；须 .ziyan_bbframe_on 才轮询。
TWEAK_NAME = ZiYanVol ZiYanFrameRelay ZiYanAppTouch ZiYanDefense ZiYanFsCloak ZiYanBBFrame ZiYanBBTouch

SHARED = objc/shared/ZiYanScriptRunner.m objc/shared/ZiYanEngine.m \
	objc/shared/ZiYanControlShm.m \
	objc/shared/ZiYanHIDOptimizer.m \
	objc/shared/ZiYanFrameTrace.m
INC = -Iobjc/shared -Iobjc/tweak/springboard -Iobjc/tweak/apptouch -Iobjc/tweak/defense -Iobjc/tweak/fscloak -Iobjc/app

ZiYan_FILES = \
	objc/app/main.m \
	objc/app/ceshiAppDelegate.m \
	objc/app/ceshiRootViewController.m \
	objc/app/ZiYanHomeViewController.m \
	objc/app/ZiYanChatFixtureViewController.m \
	objc/app/AgentGameViewController.m \
	objc/app/AgentSessionController.m \
	objc/app/AgentLearningRecorder.m \
	objc/app/AgentLearningCompiler.m \
	objc/app/AgentABCPackets.m \
	objc/app/AgentAutonomousEngine.m \
	objc/app/AgentVersionStore.m \
	objc/shared/AgentLearningInputBridge.m \
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
ifneq ($(FINALPACKAGE),1)
ZiYan_CFLAGS += -DZIYAN_PAGE_SELFTEST=1
ZIYAN_INJECT_TRACE_CFLAGS = -DZIYAN_INJECT_TRACE=1
endif
# 绝对路径：rootless remap 时 cwd 可能不在仓库根，相对 -Sobjc/app/... 会 ldid errno=2
ZiYan_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/objc/app/entitlements.plist

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
ZiYanVol_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) -DZIYAN_DAEMON_V2=1 -DZIYAN_T6_STEP7=1 $(ZIYAN_INJECT_TRACE_CFLAGS)
ZiYanVol_FRAMEWORKS = UIKit Foundation CoreFoundation MediaPlayer AVFoundation IOKit CoreGraphics QuartzCore Vision ImageIO IOSurface
# NOTE: ZiYanVol_CFLAGS 已上移；勿重复定义
ZiYanVol_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

ZiYanVol_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib -weak_framework IOSurface

# 8-159：极薄合帧中继。ScreenBridge 的唯一实现归 ZiYanVol；FrameRelay 只在
# 延迟窗口后向该共享 bridge 发消息。此前两份 dylib 都编进同名 Objective-C 类，
# iOS 13 重启后的类装载顺序不确定，会造成 relay 落到未初始化实例、截图黑帧。
ZiYanFrameRelay_FILES = \
	objc/tweak/framerelay/Tweak.m
ZiYanFrameRelay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) -DZIYAN_DAEMON_V2=1 -DZIYAN_FRAME_RELAY_ONLY=1 $(ZIYAN_INJECT_TRACE_CFLAGS)
ZiYanFrameRelay_FRAMEWORKS = UIKit Foundation CoreFoundation IOKit CoreGraphics QuartzCore Vision ImageIO IOSurface
ZiYanFrameRelay_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ZiYanFrameRelay_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanFrameRelay.dylib -weak_framework IOSurface

ZiYanAppTouch_FILES = \
	objc/tweak/apptouch/ZiYanAppTouch.m \
	objc/tweak/apptouch/ZiYanMemHook.m \
	objc/shared/ZiYanScriptRecorder.m \
	objc/shared/ZiYanFrameShm.m \
	objc/shared/AgentLearningInputBridge.m
ZiYanAppTouch_FRAMEWORKS = Foundation UIKit IOKit QuartzCore CoreGraphics
ZiYanAppTouch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) $(ZIYAN_INJECT_TRACE_CFLAGS)
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
ZiYanBBFrame_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) $(ZIYAN_INJECT_TRACE_CFLAGS)
ZiYanBBFrame_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
ZiYanBBFrame_LDFLAGS = -install_name $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanBBFrame.dylib -weak_framework IOSurface -weak_framework UIKit

ZiYanDefense_FILES = \
	objc/tweak/defense/ZiYanDefense.m \
	objc/tweak/defense/ZiYanDefenseAI.m
ZiYanDefense_FRAMEWORKS = Foundation UIKit
ZiYanDefense_LIBRARIES = substrate
ZiYanDefense_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) $(ZIYAN_INJECT_TRACE_CFLAGS)
ZiYanDefense_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# USB/AFC 越狱路径伪装（爱思等）；仅 afcd/afc2d
ZiYanFsCloak_FILES = objc/tweak/fscloak/ZiYanFsCloak.m
ZiYanFsCloak_FRAMEWORKS = Foundation
ZiYanFsCloak_LIBRARIES = substrate
ZiYanFsCloak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations $(INC) $(ZIYAN_INJECT_TRACE_CFLAGS)
ZiYanFsCloak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = ziyan_ocr ziyan_mem ziyan_plist ziyan_portspace ziyan_framecap ziyan_framecap_bootstrap ziyan_scriptgen_smoke ziyanctl ziyadaemond ziyan_shm_selftest ziyan_iomfb_diag ziyan_a_probe
ziyan_plist_FILES = tools/ziyan_plist/main.m
ziyan_plist_FRAMEWORKS = Foundation
ziyan_plist_CFLAGS = -fobjc-arc
ziyan_plist_INSTALL_PATH = /usr/lib/ziyan/bin
ziyan_ocr_FILES = tools/ziyan_ocr/main.m tools/ziyan_ocr/ziyan_fontocr.m
ziyan_ocr_FRAMEWORKS = Foundation UIKit Vision CoreGraphics ImageIO CoreImage CoreText
ziyan_ocr_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Itools/ziyan_ocr
ziyan_ocr_INSTALL_PATH = /usr/lib/ziyan/bin
ifneq ($(wildcard vendor/tesseract-ios3/lib/libtesseract.a),)
ziyan_ocr_FILES += tools/ziyan_ocr/ziyan_tess.m tools/ziyan_ocr/ziyan_tess_engine.c
ziyan_ocr_CFLAGS += -DZIYAN_HAS_TESS=1 -Ivendor/tesseract-ios3/include/tesseract
ziyan_ocr_LDFLAGS = -Lvendor/tesseract-ios3/lib -ltesseract -llept -lpng -ljpeg -ltiff -lc++ -lz
endif

ziyan_mem_FILES = tools/ziyan_mem/main.m
ziyan_mem_FRAMEWORKS = Foundation
ziyan_mem_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ziyan_mem_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_mem/entitlements.plist
ziyan_mem_INSTALL_PATH = /usr/lib/ziyan/bin

# 一次性端口空间采样；复用 ziyan_mem 的 task_for_pid entitlement。
# 采样器自身在每次读取后释放 task port，禁止常驻/轮询。
ziyan_portspace_FILES = tools/ziyan_portspace/main.m
ziyan_portspace_FRAMEWORKS = Foundation
ziyan_portspace_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ziyan_portspace_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_mem/entitlements.plist
ziyan_portspace_INSTALL_PATH = /usr/lib/ziyan/bin

ziyan_framecap_bootstrap_FILES = tools/ziyan_framecap_bootstrap/main.c
ziyan_framecap_bootstrap_INSTALL_PATH = /usr/lib/ziyan/bin
ziyan_framecap_bootstrap_CFLAGS = -Os -fvisibility=hidden
ziyan_framecap_bootstrap_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_framecap_bootstrap/entitlements.plist

ziyan_framecap_FILES = \
	tools/ziyan_framecap/main.m \
	tools/ziyan_framecap/ZiYanLuaEmbed.m \
	tools/ziyan_framecap/ZiYanSnapshotHttp.m \
	tools/ziyan_framecap/ZiYanAppFrameClient.m \
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
	-Itools/ziyan_framecap \
	-Itools/ziyan_ncnn_findcolor -Ivendor/lua-5.3.5/src -fvisibility=hidden \
	-DLUA_COMPAT_5_2 -Wno-string-plus-int -Wno-unused-parameter
ziyan_framecap_CCFLAGS = -std=c++14 -fno-modules -fvisibility=hidden \
	-Ivendor/ncnn-ios/ncnn.framework/Headers \
	-Itools/ziyan_ncnn_findcolor
ziyan_framecap_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_framecap/entitlements.plist
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

# IOMFB 逐层坐实诊断（取证工具，不参与运行路径）
# 必须与 ziyan_framecap 同一份 entitlements：IOMobileFramebufferGetLayerDefaultSurface
# 需要 iokit-user-client-class 里的 IOMobileFramebufferUserClient，否则层 0 直接回
# 0xE00002C1（kIOReturnNotPrivileged），诊断结论与守护实际能力不符。
ziyan_iomfb_diag_FILES = tools/ziyan_iomfb_diag/main.m
ziyan_iomfb_diag_FRAMEWORKS = Foundation CoreGraphics ImageIO IOKit UIKit QuartzCore
ziyan_iomfb_diag_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared
ziyan_iomfb_diag_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_framecap/entitlements.plist
ziyan_iomfb_diag_INSTALL_PATH = /usr/lib/ziyan/bin

# A 探针：一次性候选源抓帧。禁止写生产 shm，不常驻，不替代 framecap。
ziyan_a_probe_FILES = \
	tools/ziyan_a_probe/main.m \
	objc/shared/ZiYanFrameCapture.m \
	objc/shared/ZiYanFrameShm.m
ziyan_a_probe_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore IOSurface ImageIO
ziyan_a_probe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iobjc/shared
ziyan_a_probe_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_framecap/entitlements.plist
ziyan_a_probe_INSTALL_PATH = /usr/lib/ziyan/bin
ziyan_a_probe_LDFLAGS = -weak_framework IOSurface -weak_framework QuartzCore

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
ziyan_scriptgen_smoke_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/tools/ziyan_mem/entitlements.plist
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

.PHONY: stage-runtime package-rootless package-rootful clean-user-bins validate-substrate-plists

# Theos treats <TWEAK_NAME>.plist in the project root as the injection filter.
# AppTouch must load in arbitrary foreground UIKit Apps; the constructor owns
# the runtime exclusions for SpringBoard, ZiYan, and non-App processes.
validate-substrate-plists:
	@plutil -lint "$(CURDIR)/ZiYanAppTouch.plist" >/dev/null
	@/usr/libexec/PlistBuddy -c 'Print :Filter:Classes' "$(CURDIR)/ZiYanAppTouch.plist" 2>/dev/null | \
		grep -Fq 'UIApplication' || { \
		echo "FAIL: ZiYanAppTouch.plist must match UIApplication class" >&2; \
		exit 2; \
		}
	@! /usr/libexec/PlistBuddy -c 'Print :Filter:Bundles' "$(CURDIR)/ZiYanAppTouch.plist" 2>/dev/null || { \
		echo "FAIL: ZiYanAppTouch.plist must not use a framework Bundle filter" >&2; \
		exit 2; \
		}
	@! grep -Eq 'com\.(xztl\.ios|ychj\.hlhjlygr|zsyxs180\.game|ljzbbadao\.game|ownbook\.notes)' "$(CURDIR)/ZiYanAppTouch.plist" || { \
			echo "FAIL: ZiYanAppTouch.plist contains a product game Bundle allowlist" >&2; \
			exit 2; \
		}
	@! grep -Fq '<key>clang_version</key>' "$(CURDIR)/ZiYanAppTouch.plist" || { \
		echo "FAIL: ZiYanAppTouch.plist was overwritten by clang static-analyzer output" >&2; \
		exit 2; \
	}

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
	@# tmp_shots 是真机采样和 P2/P3/P6/P8 的证据库，构建不得删除其中任何文件。
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

before-all:: validate-substrate-plists clean-user-bins

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
	mkdir -p "$$DEST/usr/lib/ziyan/lib/lua/agent"; \
	rsync -a Agent/ "$$DEST/usr/lib/ziyan/lib/lua/agent/"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/lua5.3" \
		"$$DEST/usr/lib/ziyan/bin/python3.7" 2>/dev/null || true; \
	ln -sfn lua5.3 "$$DEST/usr/lib/ziyan/bin/lua"; \
	ln -sfn python3.7 "$$DEST/usr/lib/ziyan/bin/python3"; \
	ln -sfn libreadline.8.0.dylib "$$DEST/usr/lib/ziyan/lib/libreadline.8.dylib"; \
	if [ -n "$(THEOS_PACKAGE_INSTALL_PREFIX)" ]; then \
		ROOTLESS_LIB="$(THEOS_PACKAGE_INSTALL_PREFIX)/usr/lib/ziyan/lib"; \
		ROOTLESS_SYS="$(THEOS_PACKAGE_INSTALL_PREFIX)/usr/lib"; \
		install_name_tool -change /usr/lib/ziyan/lib/liblua5.3.dylib \
			"$$ROOTLESS_LIB/liblua5.3.dylib" "$$DEST/usr/lib/ziyan/bin/lua5.3"; \
		install_name_tool -change /usr/lib/ziyan/lib/libreadline.8.dylib \
			"$$ROOTLESS_LIB/libreadline.8.dylib" "$$DEST/usr/lib/ziyan/bin/lua5.3"; \
		install_name_tool -id "$$ROOTLESS_LIB/liblua5.3.dylib" \
			"$$DEST/usr/lib/ziyan/lib/liblua5.3.dylib"; \
		install_name_tool -id "$$ROOTLESS_LIB/libreadline.8.0.dylib" \
			"$$DEST/usr/lib/ziyan/lib/libreadline.8.0.dylib"; \
		install_name_tool -change /usr/lib/libncurses.6.dylib \
			"$$ROOTLESS_SYS/libncurses.6.dylib" \
			"$$DEST/usr/lib/ziyan/lib/libreadline.8.0.dylib"; \
		ldid -S "$$DEST/usr/lib/ziyan/bin/lua5.3" \
			"$$DEST/usr/lib/ziyan/lib/liblua5.3.dylib" \
			"$$DEST/usr/lib/ziyan/lib/libreadline.8.0.dylib"; \
	fi; \
	cp -f vendor/runtime/engine/wnriakwyww "$$DEST/usr/lib/ziyan/engine/wnriakwyww"; \
	cp -f vendor/runtime/engine/wnriakwyww.dylib "$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
	chmod 755 "$$DEST/usr/lib/ziyan/engine/wnriakwyww" \
		"$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
	# legacy engine links /bin/wnriakwyww.dylib. Rootful keeps that via postinst;
	# rootless cannot write /bin, so rewrite both the executable load command and
	# dylib install name to /var/jb/bin, then re-sign the modified artifacts. \
	if [ -n "$(THEOS_PACKAGE_INSTALL_PREFIX)" ]; then \
		install_name_tool -change /bin/wnriakwyww.dylib "$(THEOS_PACKAGE_INSTALL_PREFIX)/bin/wnriakwyww.dylib" \
			"$$DEST/usr/lib/ziyan/engine/wnriakwyww"; \
		install_name_tool -id "$(THEOS_PACKAGE_INSTALL_PREFIX)/bin/wnriakwyww.dylib" \
			"$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
		ldid -S "$$DEST/usr/lib/ziyan/engine/wnriakwyww"; \
		ldid -S "$$DEST/usr/lib/ziyan/engine/wnriakwyww.dylib"; \
	fi; \
	rsync -a --delete vendor/runtime/data/ "$$DEST/usr/lib/ziyan/runtime/"; \
	mkdir -p "$$DEST/usr/lib/ziyan/runtime/scripts" \
		"$$DEST/usr/lib/ziyan/runtime/var/log" \
		"$$DEST/usr/lib/ziyan/runtime/var/tmp"; \
	cp -f vendor/runtime/hook/ZiYanTEHook.dylib "$$DEST/usr/lib/ziyan/hook/"; \
	cp -f vendor/runtime/hook/ZiYanTEHook.plist "$$DEST/usr/lib/ziyan/hook/"; \
	rsync -a --delete vendor/modules/ "$$DEST/usr/lib/ziyan/modules/"; \
	rsync -a layout/usr/lib/ziyan/models/ "$$DEST/usr/lib/ziyan/models/" 2>/dev/null || true; \
	mkdir -p "$$DEST/usr/lib/ziyan/tessdata/lstm/tessdata"; \
	rsync -a layout/usr/lib/ziyan/tessdata/ "$$DEST/usr/lib/ziyan/tessdata/" 2>/dev/null || true; \
	cp -f layout/usr/lib/ziyan/tessdata/_fast/chi_sim.traineddata \
		"$$DEST/usr/lib/ziyan/tessdata/lstm/tessdata/chi_sim.traineddata" 2>/dev/null || true; \
	cp -f layout/usr/lib/ziyan/tessdata/_fast/eng.traineddata \
		"$$DEST/usr/lib/ziyan/tessdata/lstm/tessdata/eng.traineddata" 2>/dev/null || true; \
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
	: "framecap launch chain uses versioned layout, not stale vendor copies"; \
	cp -f layout/usr/lib/ziyan/bin/ziyan_zydaemond.sh \
		"$$DEST/usr/lib/ziyan/bin/ziyan_zydaemond.sh"; \
	chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_zydaemond.sh"; \
		cp -f layout/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh \
			"$$DEST/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh"; \
		chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_framecap_wrap.sh"; \
		cp -f layout/usr/lib/ziyan/bin/ziyan_runtime_root.sh \
			"$$DEST/usr/lib/ziyan/bin/ziyan_runtime_root.sh"; \
		chmod 755 "$$DEST/usr/lib/ziyan/bin/ziyan_runtime_root.sh"; \
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

.PHONY: rewrite-rootless-tehook
rewrite-rootless-tehook: stage-runtime
	@if [ -n "$(THEOS_PACKAGE_INSTALL_PREFIX)" ]; then \
		DEST="$(THEOS_STAGING_DIR)"; \
		for TEHOOK in \
			"$$DEST/Library/MobileSubstrate/DynamicLibraries/ZiYanTEHook.dylib" \
			"$$DEST$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanTEHook.dylib"; do \
			[ -f "$$TEHOOK" ] || continue; \
			install_name_tool -id "$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/ZiYanTEHook.dylib" "$$TEHOOK"; \
			install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
				@rpath/CydiaSubstrate.framework/CydiaSubstrate "$$TEHOOK"; \
			ldid -S "$$TEHOOK"; \
		done; \
	fi

after-stage:: rewrite-rootless-tehook

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
