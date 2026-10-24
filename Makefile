APP_NAME := SamsungCameraDownloader
APP_BUNDLE := $(APP_NAME).app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_INFO := $(APP_BUNDLE)/Contents/Info.plist
SWIFT := swiftc
SWIFT_FLAGS := -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 -framework SwiftUI -framework Network -framework AppKit

.PHONY: all build run clean

all: build

build: $(APP_BUNDLE)

$(APP_EXECUTABLE): SamsungCameraDownloader.swift
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	$(SWIFT) SamsungCameraDownloader.swift -o $@ $(SWIFT_FLAGS)

$(APP_INFO): $(APP_EXECUTABLE)
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
		'<key>CFBundleIdentifier</key><string>local.samsung-camera-downloader</string>' \
		'<key>CFBundleName</key><string>Samsung Camera Downloader</string>' \
		'<key>CFBundlePackageType</key><string>APPL</string>' \
		'<key>CFBundleShortVersionString</key><string>1.0</string>' \
		'<key>CFBundleVersion</key><string>1</string>' \
		'<key>LSMinimumSystemVersion</key><string>13.0</string>' \
		'<key>NSLocalNetworkUsageDescription</key><string>Samsung Camera Downloader needs local network access to connect to your camera.</string>' \
		'<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>' \
		'</dict></plist>' > $(APP_BUNDLE)/Contents/Info.plist

$(APP_BUNDLE): $(APP_EXECUTABLE) $(APP_INFO)

run: build
	open $(APP_BUNDLE)

clean:
	rm -rf $(APP_BUNDLE)
