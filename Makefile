ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PiPTweak
PiPTweak_FILES = Tweak.x
PiPTweak_LDFLAGS = -install_name @executable_path/Frameworks/PiPTweak.dylib

include $(THEOS)/makefiles/library.mk
