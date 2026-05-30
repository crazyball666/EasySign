#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"

rg -n "@Published var resignSuccessOutputPath: String\\?" "$CONTENT_VIEW" >/dev/null
rg -n '\.alert\("重签成功", isPresented: Binding\(value: \$viewModel\.resignSuccessOutputPath\)\)' "$CONTENT_VIEW" >/dev/null
rg -n "IPA 已导出到" "$CONTENT_VIEW" >/dev/null
rg -n "viewModel\\.resignSuccessOutputPath = taskInfo\\.outputPath\\.path" "$CONTENT_VIEW" >/dev/null

python3 - "$CONTENT_VIEW" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
success = text.index("try ResignTask(taskInfo: taskInfo, logger: viewModel).Start()")
assignment = text.index("viewModel.resignSuccessOutputPath = taskInfo.outputPath.path")
catch = text.index("} catch {", success)
if not success < assignment < catch:
    raise SystemExit(1)
PY
