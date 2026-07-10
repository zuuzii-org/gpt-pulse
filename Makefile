.PHONY: generate build test test-swift test-plugin check clean open

DERIVED_DATA := .build/DerivedData

generate:
	xcodegen generate

build: generate
	xcodebuild -project GPTPulse.xcodeproj -scheme GPTPulse -configuration Debug -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

test: test-swift test-plugin

test-swift: generate
	xcodebuild -project GPTPulse.xcodeproj -scheme GPTPulse -configuration Debug -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO test

test-plugin:
	python3 -m unittest discover -s Tests/Plugin -p 'test_*.py' -v

check: test build

open: generate
	open GPTPulse.xcodeproj

clean:
	xcodebuild -project GPTPulse.xcodeproj -scheme GPTPulse -derivedDataPath $(DERIVED_DATA) clean
