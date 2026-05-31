#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"
QRCODE_VIEW="EasySign/Views/QRCodeToolView.swift"
QRCODE_SERVICE="EasySign/Tools/QRCodeService.swift"

test -f "$QRCODE_VIEW"
test -f "$QRCODE_SERVICE"

rg -n 'case qrcode = "二维码"' "$CONTENT_VIEW" >/dev/null
rg -n 'tab == \.qrcode \? "qrcode"' "$CONTENT_VIEW" >/dev/null
rg -n 'case \.qrcode:' "$CONTENT_VIEW" >/dev/null
rg -n 'QRCodeToolView\(\)' "$CONTENT_VIEW" >/dev/null

rg -n 'struct QRCodeToolView: View' "$QRCODE_VIEW" >/dev/null
rg -n '生成二维码' "$QRCODE_VIEW" >/dev/null
rg -n '复制二维码' "$QRCODE_VIEW" >/dev/null
rg -n '保存二维码' "$QRCODE_VIEW" >/dev/null
rg -n 'AirDrop' "$QRCODE_VIEW" >/dev/null
rg -n '扫描屏幕上的二维码' "$QRCODE_VIEW" >/dev/null

rg -n 'enum QRCodeService' "$QRCODE_SERVICE" >/dev/null
rg -n 'makeQRCodeImage\(text: String, size: CGSize\)' "$QRCODE_SERVICE" >/dev/null
rg -n 'scanScreen\(\)' "$QRCODE_SERVICE" >/dev/null
