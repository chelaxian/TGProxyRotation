# Vanilla Theos on this machine has no `roothide` package scheme, so we follow
# the proven HPPE pattern: build a rootless dylib+deb with the default `deb`
# scheme; RootHide Bootstrap installs this form (see com.ratush.hppe).
# Build rootless arm64 first, then run RootHide Patcher on-device to produce
# the arm64e/PAC-correct package. Direct Linux arm64e builds produce an
# incompatible ABI warning and can prevent Telegram from launching.
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Telegram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TGProxyRotation

TGProxyRotation_FILES = \
	Tweak.x \
	Logger.m

TGProxyRotation_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability -Wno-unused-function
TGProxyRotation_FRAMEWORKS = UIKit Foundation Security
TGProxyRotation_LDFLAGS = -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/TGProxyRotation.dylib
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	$(ECHO_NOTHING)ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/TGProxyRotation.dylib.roothidepatch"$(ECHO_END)
