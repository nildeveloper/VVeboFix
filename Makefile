# 通用配置 - 兼容所有环境
export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = VVebo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VVeboFix

VVeboFix_FILES = VVeboFix.m
VVeboFix_CFLAGS = -fobjc-arc
VVeboFix_FRAMEWORKS = Foundation UIKit
VVeboFix_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 VVebo || true"
