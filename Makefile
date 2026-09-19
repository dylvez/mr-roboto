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

.PHONY: check build test test-mlx cli doctor clean app evals capture

check: build test test-mlx cli doctor
	@echo "check: ok"

build:
	swift build

test:
	swift test --skip AnalysisMLXTests

# Note the tee on these two: piping xcodebuild straight into grep reports grep's exit status, so
# a failing test would print a failure and still leave `make check` green.
test-mlx:
	@$(XCT) test -scheme MrRoboto-Package -only-testing:AnalysisMLXTests 2>&1 | tee .build/mlx-test.log | grep -E "Test run with|\*\* TEST" || true
	@grep -q "\*\* TEST SUCCEEDED" .build/mlx-test.log || (echo "MLX tests failed; see .build/mlx-test.log" && exit 1)

cli:
	@$(XC) build -scheme m0 -configuration Debug 2>&1 | tee .build/cli-build.log | grep -E "\*\* BUILD" || true
	@grep -q "\*\* BUILD SUCCEEDED" .build/cli-build.log || (echo "m0 build failed; see .build/cli-build.log" && exit 1)
	@test -x $(DD)/Build/Products/Debug/m0 || (echo "m0 missing from xcodebuild products" && exit 1)
	@test -d $(DD)/Build/Products/Debug/mlx-swift_Cmlx.bundle || (echo "MLX metal bundle missing from xcodebuild products" && exit 1)

doctor:
	.build/out/Products/Debug/m0 doctor
	$(DD)/Build/Products/Debug/m0 doctor

# The persona evals: every golden, disagreement and blind sheet, reported to Bench/personas/evals.md.
# `make check` already runs the goldens and the disagreements as tests; this adds the blind sheets
# and writes the report.
evals:
	swift build --build-tests
	MRROBOTO_EVALS=1 swift test --skip-build --filter PersonaEvalTests

# Roboto Capture, the phone half of M5: generated with xcodegen and built for the simulator.
# Not part of `check`: it needs the iOS SDK and takes a minute. The device build is yours.
capture:
	cd Capture && xcodegen generate
	xcodebuild -project Capture/RobotoCapture.xcodeproj -scheme RobotoCapture -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/capture \
	  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee .build/capture-build.log | grep -E "\*\* BUILD|error:" || true
	@grep -q "\*\* BUILD SUCCEEDED" .build/capture-build.log || (echo "capture build failed; see .build/capture-build.log" && exit 1)

# The packaged Mac app, signed and installed to ~/Applications. See scripts/make-app.sh.
app:
	scripts/make-app.sh

clean:
	rm -rf .build
