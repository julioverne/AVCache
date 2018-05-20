include theos/makefiles/common.mk

TWEAK_NAME = AVCache

AVCache_FILES = /mnt/d/codes/avcache/AVCache.xm
AVCache_FRAMEWORKS = CydiaSubstrate UIKit Foundation MobileCoreServices
AVCache_LDFLAGS = -Wl,-segalign,4000

export ARCHS = armv7 arm64
AVCache_ARCHS = armv7 arm64 

include $(THEOS_MAKE_PATH)/tweak.mk

all::

	