#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"

rg -n "struct InjectedDylibPickerView" "$CONTENT_VIEW" >/dev/null
rg -n "自定义动态库|添加动态库|移除动态库|清空动态库" "$CONTENT_VIEW" >/dev/null
rg -n "DylibInjection\\.mergePaths" "$CONTENT_VIEW" >/dev/null
rg -n "DylibInjection\\.removePath" "$CONTENT_VIEW" >/dev/null
rg -n "injectedDylibPaths: viewModel\\.injectedDylibPaths\\.map" "$CONTENT_VIEW" >/dev/null
