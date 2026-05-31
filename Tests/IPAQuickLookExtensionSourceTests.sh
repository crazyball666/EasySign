#!/bin/sh
set -eu

PROJECT="EasySign.xcodeproj/project.pbxproj"
APP_INFO="EasySign/Info.plist"
EXT_INFO="EasySignQuickLook/Info.plist"
EXT_PROVIDER="EasySignQuickLook/PreviewViewController.swift"
HTML_RENDERER="EasySign/ResignService/Model/IPAPreviewHTMLRenderer.swift"
PREVIEW_SERVICE="EasySign/ResignService/Model/IPAPreviewService.swift"

test -f "$APP_INFO"
test -f "$EXT_INFO"
test -f "$EXT_PROVIDER"
test -f "$HTML_RENDERER"
test -f "$PREVIEW_SERVICE"

rg -n "EasySignQuickLook" "$PROJECT" >/dev/null
rg -n "EasySignQuickLook\\.appex in Embed Foundation Extensions" "$PROJECT" >/dev/null
rg -n "com\\.apple\\.product-type\\.app-extension" "$PROJECT" >/dev/null
rg -n "PBXTargetDependency" "$PROJECT" >/dev/null
rg -n "INFOPLIST_FILE = EasySign/Info\\.plist" "$PROJECT" >/dev/null

rg -n "CFBundleDocumentTypes" "$APP_INFO" >/dev/null
rg -n "LSItemContentTypes" "$APP_INFO" >/dev/null
rg -n "UTImportedTypeDeclarations" "$APP_INFO" >/dev/null
rg -n "UTTypeIdentifier" "$APP_INFO" >/dev/null
rg -n "com\\.apple\\.itunes\\.ipa" "$APP_INFO" >/dev/null
rg -n "public\\.filename-extension" "$APP_INFO" >/dev/null
rg -n "<string>ipa</string>" "$APP_INFO" >/dev/null

rg -n "com\\.apple\\.quicklook\\.preview" "$EXT_INFO" >/dev/null
rg -n "QLIsDataBasedPreview" "$EXT_INFO" >/dev/null
rg -n "<false/>" "$EXT_INFO" >/dev/null
rg -n "\\$\\(PRODUCT_MODULE_NAME\\)\\.PreviewViewController" "$EXT_INFO" >/dev/null
rg -n "UTImportedTypeDeclarations" "$EXT_INFO" >/dev/null
rg -n "UTTypeIdentifier" "$EXT_INFO" >/dev/null
rg -n "com\\.apple\\.itunes\\.ipa" "$EXT_INFO" >/dev/null
rg -n "public\\.filename-extension" "$EXT_INFO" >/dev/null
rg -n "<string>ipa</string>" "$EXT_INFO" >/dev/null
rg -n "UTTypeConformsTo" "$EXT_INFO" >/dev/null
rg -n "public\\.zip-archive" "$EXT_INFO" >/dev/null

rg -n "final class PreviewViewController: NSViewController, QLPreviewingController" "$EXT_PROVIDER" >/dev/null
! rg -n "WKWebView|import WebKit|loadHTMLString" "$EXT_PROVIDER" >/dev/null
rg -n "preparePreviewOfFile\\(at url: URL\\)" "$EXT_PROVIDER" >/dev/null
rg -n "IPAPreviewService\\(\\)\\.preview\\(url: url\\)" "$EXT_PROVIDER" >/dev/null
rg -n "NSScrollView" "$EXT_PROVIDER" >/dev/null
rg -n "NSStackView" "$EXT_PROVIDER" >/dev/null
rg -n "render\\(info: info\\)" "$EXT_PROVIDER" >/dev/null
rg -n "static func html\\(for info: IPAPreviewInfo\\)" "$HTML_RENDERER" >/dev/null
! rg -n "/usr/bin/(unzip|security)" "$PREVIEW_SERVICE" >/dev/null
! rg -n "Process\\(" "$PREVIEW_SERVICE" >/dev/null
