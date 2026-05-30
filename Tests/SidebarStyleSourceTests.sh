#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"

rg -n "@State private var isHovered = false" "$CONTENT_VIEW" >/dev/null
rg -n '\.onHover \{ isHovered = \$0 \}' "$CONTENT_VIEW" >/dev/null
rg -n "Capsule\\(style: \\.continuous\\)" "$CONTENT_VIEW" >/dev/null
rg -n "\\.fill\\(Color\\.accentColor\\)" "$CONTENT_VIEW" >/dev/null
rg -n "\\.frame\\(width: 3, height: 28\\)" "$CONTENT_VIEW" >/dev/null
rg -n "Color\\(nsColor: \\.separatorColor\\)" "$CONTENT_VIEW" >/dev/null
rg -n "Color\\.secondary" "$CONTENT_VIEW" >/dev/null
