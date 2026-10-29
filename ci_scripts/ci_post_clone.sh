#!/bin/sh
# Xcode Cloud runs this right after cloning. Dove.xcodeproj is generated from project.yml (XcodeGen) and
# git-ignored, so the project has to be made here before Xcode Cloud looks for it.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
brew install xcodegen
xcodegen generate
