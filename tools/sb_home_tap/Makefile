TARGET := iphone:clang:latest:13.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ZiYanHomeTap
ZiYanHomeTap_FILES = Tweak.m
ZiYanHomeTap_CFLAGS = -fobjc-arc
ZiYanHomeTap_FRAMEWORKS = UIKit Foundation
include $(THEOS_MAKE_PATH)/tweak.mk
