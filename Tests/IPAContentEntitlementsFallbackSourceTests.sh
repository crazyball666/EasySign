#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"

rg -n "let entitlements = \\(try\\? appBundle\\.getEntitlementsString\\(\\)\\) \\?\\? \"\"" "$CONTENT_VIEW" >/dev/null
rg -n "entitlements: entitlements" "$CONTENT_VIEW" >/dev/null

if rg -n "Read entitlements error" "$CONTENT_VIEW" >/dev/null; then
  exit 1
fi
