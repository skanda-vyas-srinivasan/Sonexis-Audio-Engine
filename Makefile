APP_NAME := ProcessTapDSP
BUNDLE_ID := com.sonexis.prototype.ProcessTapDSP
DEPLOYMENT_TARGET := 14.4
ARCH := $(shell uname -m)
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD_DIR := .build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
MODULE_CACHE := $(BUILD_DIR)/module-cache

SWIFT_SOURCES := \
	Sources/CoreAudioSupport.swift \
	Sources/ProcessTapDSPPrototype.swift \
	Sources/main.swift

C_SOURCES := \
	Sources/RealtimeAudioRing.c

C_OBJECTS := \
	$(BUILD_DIR)/RealtimeAudioRing.o

SWIFT_FLAGS := \
	-sdk $(SDKROOT) \
	-target $(ARCH)-apple-macos$(DEPLOYMENT_TARGET) \
	-module-cache-path $(MODULE_CACHE) \
	-import-objc-header Sources/RealtimeAudioRing.h \
	-framework AppKit \
	-framework CoreAudio

C_FLAGS := \
	-isysroot $(SDKROOT) \
	-target $(ARCH)-apple-macos$(DEPLOYMENT_TARGET) \
	-std=c11 \
	-O2

.PHONY: all clean run

all: $(APP_BUNDLE)

$(BUILD_DIR)/RealtimeAudioRing.o: $(C_SOURCES) Sources/RealtimeAudioRing.h
	mkdir -p "$(BUILD_DIR)"
	xcrun clang $(C_FLAGS) -c Sources/RealtimeAudioRing.c -o "$(BUILD_DIR)/RealtimeAudioRing.o"

$(APP_BUNDLE): $(SWIFT_SOURCES) $(C_OBJECTS) Info.plist
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(MODULE_CACHE)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(APP_BUNDLE)/Contents/Info.plist"
	MACOSX_DEPLOYMENT_TARGET=$(DEPLOYMENT_TARGET) xcrun swiftc $(SWIFT_FLAGS) $(SWIFT_SOURCES) $(C_OBJECTS) -o "$(EXECUTABLE)"
	codesign --force --sign - --timestamp=none "$(APP_BUNDLE)"

run: $(APP_BUNDLE)
	"$(EXECUTABLE)"

clean:
	rm -rf "$(BUILD_DIR)"
