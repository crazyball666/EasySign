#!/bin/sh
set -e

PREVIEW_SERVICE="EasySign/ResignService/Model/IPAPreviewService.swift"

rg -n "IPAPreviewTiming" "$PREVIEW_SERVICE" >/dev/null
rg -n "timing.step\\(\"loadEntries\"" "$PREVIEW_SERVICE" >/dev/null
rg -n "Logger" "$PREVIEW_SERVICE" >/dev/null
rg -n "#if DEBUG" "$PREVIEW_SERVICE" >/dev/null
rg -n "entriesByName" "$PREVIEW_SERVICE" >/dev/null

if rg -n "NSLog\\(" "$PREVIEW_SERVICE" >/dev/null; then
  echo "IPAPreview timing should use os.Logger instead of NSLog" >&2
  exit 1
fi

if rg -n "private let entries:" "$PREVIEW_SERVICE" >/dev/null; then
  echo "ZIPArchiveReader should not keep both entries and entriesByName in memory" >&2
  exit 1
fi

if rg -n "func entryNames\\(" "$PREVIEW_SERVICE" >/dev/null; then
  echo "ZIPArchiveReader should expose direct indexed-name iteration instead of entryNames()" >&2
  exit 1
fi

if rg -n 'entries\.first\(where: \{ \$0\.name == name \}\)' "$PREVIEW_SERVICE" >/dev/null; then
  echo "ZIPArchiveReader.data(for:) must use an indexed lookup instead of a linear scan" >&2
  exit 1
fi

if rg -n "as! CFString" "$PREVIEW_SERVICE" >/dev/null; then
  echo "certificate subject parsing should not force-cast labels to CFString" >&2
  exit 1
fi

copy_values_count=$(rg -n "SecCertificateCopyValues" "$PREVIEW_SERVICE" | wc -l | tr -d ' ')
if [ "$copy_values_count" != "1" ]; then
  echo "certificate parsing should call SecCertificateCopyValues from one batched helper" >&2
  exit 1
fi
