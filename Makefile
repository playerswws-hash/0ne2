TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IslandClone
IslandClone_FILES = Tweak.x
IslandClone_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IslandClone_FRAMEWORKS = UIKit CallKit

include $(THEOS_MAKE_PATH)/tweak.mk
