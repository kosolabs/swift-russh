#!/bin/bash
# Builds the Rust core into Sources/CRusshFFI.xcframework and regenerates the
# UniFFI Swift bindings in Sources/RusshFFI.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
RUST="$ROOT/rust"
BUILD="$ROOT/.build/rust"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
LIB=librussh_ffi.a
MACOS_MIN=15.0

rm -rf "$BUILD"
mkdir -p "$BUILD"/{universal,generated,headers}

cd "$RUST"
for target in "${TARGETS[@]}"; do
  env "CFLAGS_${target//-/_}=-mmacosx-version-min=$MACOS_MIN" \
    cargo build --release --locked --target "$target"
done

lipo -create \
  $(for target in "${TARGETS[@]}"; do echo "$RUST/target/$target/release/$LIB"; done) \
  -output "$BUILD/universal/$LIB"
HOST=$(rustc -vV | sed -n 's/^host: //p')
cargo run --release --locked --target "$HOST" --bin uniffi-bindgen -- generate \
  --library "$RUST/target/$HOST/release/$LIB" \
  --language swift \
  --out-dir "$BUILD/generated"

cp "$BUILD/generated/CRusshFFI.h" "$BUILD/headers/"
cp "$BUILD/generated/CRusshFFI.modulemap" "$BUILD/headers/module.modulemap"

rm -rf "$ROOT/Sources/CRusshFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/universal/$LIB" \
  -headers "$BUILD/headers" \
  -output "$ROOT/Sources/CRusshFFI.xcframework"

mkdir -p "$ROOT/Sources/RusshFFI"
cp "$BUILD/generated/RusshFFI.swift" "$ROOT/Sources/RusshFFI/RusshFFI.swift"
