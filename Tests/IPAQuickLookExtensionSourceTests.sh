#!/bin/sh
set -eu

PROJECT="EasySign.xcodeproj/project.pbxproj"
APP_INFO="EasySign/Info.plist"
EXT_INFO="EasySignQuickLook/Info.plist"
EXT_PROVIDER="EasySignQuickLook/PreviewProvider.swift"
HTML_RENDERER="EasySign/ResignService/Model/IPAPreviewHTMLRenderer.swift"

test -f "$APP_INFO"
test -f "$EXT_INFO"
test -f "$EXT_PROVIDER"
test -f "$HTML_RENDERER"

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
rg -n "UTImportedTypeDeclarations" "$EXT_INFO" >/dev/null
rg -n "UTTypeIdentifier" "$EXT_INFO" >/dev/null
rg -n "com\\.apple\\.itunes\\.ipa" "$EXT_INFO" >/dev/null
rg -n "public\\.filename-extension" "$EXT_INFO" >/dev/null
rg -n "<string>ipa</string>" "$EXT_INFO" >/dev/null
rg -n "UTTypeConformsTo" "$EXT_INFO" >/dev/null
rg -n "public\\.zip-archive" "$EXT_INFO" >/dev/null

rg -n "class PreviewProvider: QLPreviewProvider, QLPreviewingController" "$EXT_PROVIDER" >/dev/null
rg -n "providePreview\\(for request: QLFilePreviewRequest\\)" "$EXT_PROVIDER" >/dev/null
rg -n "IPAPreviewService\\(\\)\\.preview\\(url: request\\.fileURL\\)" "$EXT_PROVIDER" >/dev/null
rg -n "IPAPreviewHTMLRenderer\\.html\\(for: info\\)" "$EXT_PROVIDER" >/dev/null
rg -n "static func html\\(for info: IPAPreviewInfo\\)" "$HTML_RENDERER" >/dev/null
