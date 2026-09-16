# M0 check: every target builds and tests, and the CLI runs an MLX computation from both build systems.
#
# Two toolchain facts baked in here (Xcode 27, Swift 6.4):
#  - xcodebuild needs -skipPackagePluginValidation because mlx-swift ships a build-tool plugin.
#  - MLX tests must run under xcodebuild: the `swift test` host cannot locate the Metal library bundle
#    that Swift Build produces (mlx-swift_Cmlx.bundle). Executables built by either tool find it fine.
#  - Anything that must make sound is run from a normal Terminal, not an automated shell.

DD = .build/xcode
XC = xcodebuild -destination 'generic/platform=macOS' -derivedDataPath $(DD) -skipPackagePluginValidation -skipMacroValidation
XCT = xcodebuild -destination 'platform=macOS' -derivedDataPath $(DD) -skipPackagePluginValidation -skipMacroValidation

.PHONY: check build test test-mlx cli doctor clean

check: build test test-mlx cli doctor
	@echo "check: ok"

build:
	swift build

test:
	swift test --skip AnalysisMLXTests

test-mlx:
	$(XCT) test -scheme MrRoboto-Package -only-testing:AnalysisMLXTests 2>&1 | grep -E "Test run with|\*\* TEST"

cli:
	$(XC) build -scheme m0 -configuration Debug 2>&1 | grep -E "\*\* BUILD"
	@test -x $(DD)/Build/Products/Debug/m0 || (echo "m0 missing from xcodebuild products" && exit 1)
	@test -d $(DD)/Build/Products/Debug/mlx-swift_Cmlx.bundle || (echo "MLX metal bundle missing from xcodebuild products" && exit 1)

doctor:
	.build/out/Products/Debug/m0 doctor
	$(DD)/Build/Products/Debug/m0 doctor

clean:
	rm -rf .build
