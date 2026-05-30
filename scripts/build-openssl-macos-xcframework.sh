#!/usr/bin/env bash
set -euo pipefail

OPENSSL_VERSION="3.5.6"
OPENSSL_SHA256="deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/openssl-${OPENSSL_VERSION}"
VENDOR_DIR="${ROOT_DIR}/EasySign/Vendor/OpenSSL"
SOURCE_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
TARBALL="${BUILD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
SRC_DIR="${BUILD_DIR}/src"
OUT_DIR="${BUILD_DIR}/out"
XCFRAMEWORK="${VENDOR_DIR}/OpenSSL.xcframework"
MACOS_MIN_VERSION="13.0"

build_arch() {
  local arch="$1"
  local configure_target="$2"
  local prefix="${OUT_DIR}/${arch}"
  local framework_dir="${BUILD_DIR}/frameworks/${arch}/OpenSSL.framework"

  rm -rf "${SRC_DIR}-${arch}" "${prefix}" "${framework_dir}"
  cp -R "${SRC_DIR}" "${SRC_DIR}-${arch}"

  pushd "${SRC_DIR}-${arch}" >/dev/null
  ./Configure "${configure_target}" \
    no-shared \
    no-tests \
    no-apps \
    no-ssl3 \
    no-comp \
    no-zlib \
    no-module \
    enable-legacy \
    "--prefix=${prefix}" \
    "--openssldir=${prefix}/ssl" \
    CFLAGS="-arch ${arch} -mmacosx-version-min=${MACOS_MIN_VERSION}"
  make -j"$(sysctl -n hw.ncpu)"
  make install_sw
  popd >/dev/null

  mkdir -p "${framework_dir}/Headers/openssl" "${framework_dir}/Modules"
  libtool -static -o "${framework_dir}/OpenSSL" "${prefix}/lib/libssl.a" "${prefix}/lib/libcrypto.a"
  rsync -a "${prefix}/include/openssl/" "${framework_dir}/Headers/openssl/"
  cat > "${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>OpenSSL</string>
  <key>CFBundleIdentifier</key>
  <string>org.openssl.OpenSSL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>OpenSSL</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${OPENSSL_VERSION}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleVersion</key>
  <string>${OPENSSL_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MACOS_MIN_VERSION}</string>
</dict>
</plist>
PLIST
  cat > "${framework_dir}/Headers/OpenSSL.h" <<'HEADER'
#pragma once
#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <openssl/pkcs12.h>
#include <openssl/cms.h>
HEADER
  cat > "${framework_dir}/Modules/module.modulemap" <<'MODULEMAP'
framework module OpenSSL {
  umbrella header "OpenSSL.h"
  export *
  module * { export * }
}
MODULEMAP
}

make_universal_framework() {
  local universal_dir="${BUILD_DIR}/frameworks/macos-arm64_x86_64/OpenSSL.framework"
  local current_dir="${universal_dir}/Versions/A"

  rm -rf "${universal_dir}"
  mkdir -p "${current_dir}/Headers" "${current_dir}/Modules" "${current_dir}/Resources"
  rsync -a "${BUILD_DIR}/frameworks/arm64/OpenSSL.framework/Headers/" "${current_dir}/Headers/"
  rsync -a "${BUILD_DIR}/frameworks/arm64/OpenSSL.framework/Modules/" "${current_dir}/Modules/"
  cp "${BUILD_DIR}/frameworks/arm64/OpenSSL.framework/Info.plist" "${current_dir}/Resources/Info.plist"
  lipo -create \
    "${BUILD_DIR}/frameworks/arm64/OpenSSL.framework/OpenSSL" \
    "${BUILD_DIR}/frameworks/x86_64/OpenSSL.framework/OpenSSL" \
    -output "${current_dir}/OpenSSL"
  ln -s A "${universal_dir}/Versions/Current"
  ln -s Versions/Current/OpenSSL "${universal_dir}/OpenSSL"
  ln -s Versions/Current/Headers "${universal_dir}/Headers"
  ln -s Versions/Current/Modules "${universal_dir}/Modules"
  ln -s Versions/Current/Resources "${universal_dir}/Resources"
}

mkdir -p "${BUILD_DIR}" "${VENDOR_DIR}"
if [ ! -f "${TARBALL}" ]; then
  curl -L "${SOURCE_URL}" -o "${TARBALL}"
fi
echo "${OPENSSL_SHA256}  ${TARBALL}" | shasum -a 256 -c -
rm -rf "${SRC_DIR}" "${OUT_DIR}" "${BUILD_DIR}/frameworks"
mkdir -p "${SRC_DIR}"
tar -xzf "${TARBALL}" --strip-components=1 -C "${SRC_DIR}"
cp "${SRC_DIR}/LICENSE.txt" "${VENDOR_DIR}/LICENSE.txt"

build_arch "arm64" "darwin64-arm64-cc"
build_arch "x86_64" "darwin64-x86_64-cc"
make_universal_framework

rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -framework "${BUILD_DIR}/frameworks/macos-arm64_x86_64/OpenSSL.framework" \
  -output "${XCFRAMEWORK}"

cat > "${VENDOR_DIR}/VERSION.txt" <<EOF
OpenSSL ${OPENSSL_VERSION} LTS
Source: ${SOURCE_URL}
SHA256: ${OPENSSL_SHA256}
Build: static macOS arm64/x86_64 xcframework
Flags: no-shared no-tests no-apps no-ssl3 no-comp no-zlib no-module enable-legacy
License: Apache License 2.0
EOF
