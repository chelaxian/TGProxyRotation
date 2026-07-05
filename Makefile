# TGProxyRotation — rootless Theos tweak build.
#
# Produces a plain rootless arm64 .dylib + .deb under the default `deb` scheme.
# This single artifact installs on:
#   - rootless jailbreaks (Dopamine / palera1n rootless / NathanLR / NekoJB)
#   - RootHide Bootstrap, which re-patches the binary on-device at install time
#     (it does NOT require the `.roothidepatch` sentinel to be pre-baked —
#      when installed from an APT repo it runs everything through patch.sh).
#
# The CI workflow (`.github/workflows/build.yml`) additionally repacks a copy
# of this deb with a `TGProxyRotation.dylib.roothidepatch` sentinel as
# `com.ratush.tgproxyrotation_<ver>_iphoneos-arm64e.deb` for users who install
# RootHide-targeted packages manually (e.g. via Sileo with the .deb file).
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
