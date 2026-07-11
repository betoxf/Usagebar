.PHONY: build release clean

PROJECT_NAME = JustaUsageBar
SCHEME = JustaUsageBar
RELEASE_APP_NAME = Usagebar
BUILD_DIR = build
ZIP_PATH = $(BUILD_DIR)/$(RELEASE_APP_NAME).zip
DERIVED_DATA_DIR ?= $(TMPDIR)UsagebarDerivedData
BUILT_APP_PATH = $(DERIVED_DATA_DIR)/Build/Products/Release/$(RELEASE_APP_NAME).app

# Build debug
build:
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		build

# Build release and create zip for distribution
release:
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/Release $(ZIP_PATH) $(DERIVED_DATA_DIR)
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA_DIR) \
		-quiet \
		build
	@cd $(dir $(BUILT_APP_PATH)) && COPYFILE_DISABLE=1 zip -r -X $(abspath $(ZIP_PATH)) $(RELEASE_APP_NAME).app
	@echo ""
	@echo "Release built: $(ZIP_PATH)"
	@echo "SHA256: $$(shasum -a 256 $(ZIP_PATH) | cut -d' ' -f1)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Create a GitHub release with tag v<version>"
	@echo "  2. Upload $(ZIP_PATH) to the release"
	@echo "  3. Update Casks/usagebar.rb and compatibility casks with the SHA256 above"

clean:
	rm -rf $(BUILD_DIR) $(DERIVED_DATA_DIR)
	xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		clean
