TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# Кладём страницу настроек в layout/ (Theos сам добавит /var/jb для rootless)
__ISL_PREFS := $(shell mkdir -p layout/Library/PreferenceLoader/Preferences && cp IslandMessengerPrefs.plist layout/Library/PreferenceLoader/Preferences/IslandMessenger.plist)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IslandMessenger
IslandMessenger_FILES = Tweak.xm
IslandMessenger_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
IslandMessenger_FRAMEWORKS = UIKit QuartzCore AVFoundation Accelerate AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
