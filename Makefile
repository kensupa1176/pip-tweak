THEOS_DEVICE_IP = 0
ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PiPTweak
PiPTweak_FILES = Tweak.x
PiPTweak_FRAMEWORKS = UIKit AVKit

include $(THEOS)/makefiles/tweak.mk
