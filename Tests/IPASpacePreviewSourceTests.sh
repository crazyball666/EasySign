#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"
PREVIEW_VIEW="EasySign/Views/IPAPreviewPanelView.swift"
PREVIEW_SERVICE="EasySign/ResignService/Model/IPAPreviewService.swift"

rg -n "@Published var ipaPreviewInfo: IPAPreviewInfo\\?" "$CONTENT_VIEW" >/dev/null
rg -n "@Published var ipaPreviewLoading = false" "$CONTENT_VIEW" >/dev/null
rg -n "Label\\(\"预览\", systemImage: \"eye\"\\)" "$CONTENT_VIEW" >/dev/null
! rg -n "\\.keyboardShortcut\\(\\.space, modifiers: \\[\\]\\)" "$CONTENT_VIEW" >/dev/null
rg -n '\.sheet\(item: \$viewModel\.ipaPreviewInfo\)' "$CONTENT_VIEW" >/dev/null
rg -n "IPAPreviewService\\(\\)\\.preview\\(url: inputURL\\)" "$CONTENT_VIEW" >/dev/null
rg -n "struct IPAPreviewPanelView: View" "$PREVIEW_VIEW" >/dev/null
rg -n "struct IPAPreviewInfo: Identifiable" "$PREVIEW_SERVICE" >/dev/null
rg -n "签名信息" "$PREVIEW_VIEW" >/dev/null
rg -n "IPAPreviewCertificate" "$PREVIEW_SERVICE" >/dev/null
rg -n "IPAPreviewCodeSignature" "$PREVIEW_SERVICE" >/dev/null
