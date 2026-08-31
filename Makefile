# Gate voor pitchlab-speech. Command Line Tools only, geen Xcode.
#
# `swift test` kaal draait GEEN tests op een CLT-only Mac: XCTest ontbreekt in de
# CLT, alleen Swift Testing (Testing.framework) is aanwezig, en die staat niet op
# het standaard framework-zoekpad. Zonder `-F` bouwt SwiftPM de test-bundle, vindt
# de helper Testing.framework niet, en eindigt met exit 0 terwijl er nul tests
# draaien — een false green. Het `-F`-pad wijst swiftc naar de frameworks; de rpath
# voor runtime zit in Package.swift.

FRAMEWORKS := $(shell xcode-select -p)/Library/Developer/Frameworks

.PHONY: build test gate

build:
	swift build -c release

test:
	swift test -Xswiftc -F -Xswiftc "$(FRAMEWORKS)"

gate: build test
