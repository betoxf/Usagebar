.PHONY: build release clean

PROJECT_NAME = JustaUsageBar
SCHEME = JustaUsageBar
RELEASE_APP_NAME = Usagebar
BUILD_DIR = build
RELEASE_DIR = $(BUILD_DIR)/Release
APP_PATH = $(RELEASE_DIR)/$(RELEASE_APP_NAME).app
ZIP_PATH = $(BUILD_DIR)/$(RELEASE_APP_NAME).zip

# Build debug
build:
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		build

# Build release and create zip for distribution
release:
	@mkdir -p $(RELEASE_DIR)
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		build
	@cp -R $(BUILD_DIR)/DerivedData/Build/Products/Release/$(RELEASE_APP_NAME).app $(RELEASE_DIR)/
	@cd $(RELEASE_DIR) && zip -r ../../$(ZIP_PATH) $(RELEASE_APP_NAME).app
	@echo ""
	@echo "Release built: $(ZIP_PATH)"
	@echo "SHA256: $$(shasum -a 256 $(ZIP_PATH) | cut -d' ' -f1)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Create a GitHub release with tag v<version>"
	@echo "  2. Upload $(ZIP_PATH) to the release"
	@echo "  3. Update Casks/usagebar.rb and compatibility casks with the SHA256 above"

clean:
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		clean
