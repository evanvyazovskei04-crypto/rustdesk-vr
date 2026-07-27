# Toolchain environment for building the Android client of this fork.
#
# Source it, don't run it:   source scripts/dev_env.sh
#
# Adjust the three *_HOME paths below if your machine differs; everything else
# is derived. See CLAUDE.md for why each pin matters.

# Flutter 3.24.5 exactly. Upstream's CI pins this (ANDROID_FLUTTER_VERSION) and
# the Dart in newer Flutter releases rejects this pubspec's constraints.
export FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"

# JDK 17, NOT the system JDK. The Gradle wrapper here is 7.6.4, which predates
# Java 21 support -- building with 21 fails inside Gradle with an unhelpful
# "Unsupported class file major version" style error.
export JAVA_HOME="${JAVA_HOME_17:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# libclang for flutter_rust_bridge_codegen's ffigen step. Xcode Command Line
# Tools ships one, so a separate LLVM install is not needed.
export LIBCLANG_PATH="${LIBCLANG_PATH:-/Library/Developer/CommandLineTools/usr/lib}"

export PATH="$FLUTTER_HOME/bin:$JAVA_HOME/bin:$HOME/.cargo/bin:$ANDROID_HOME/platform-tools:$PATH"
