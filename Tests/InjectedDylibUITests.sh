#!/bin/sh
set -eu

CONTENT_VIEW="EasySign/Views/ContentView.swift"

rg -n "struct InjectedDylibPickerView" "$CONTENT_VIEW" >/dev/null
rg -n "重签方式|zsign|系统 codesign" "$CONTENT_VIEW" >/dev/null
rg -n "动态库注入|启用动态库注入|添加动态库|移除动态库|清空动态库" "$CONTENT_VIEW" >/dev/null
rg -n "DylibInjection\\.mergePaths" "$CONTENT_VIEW" >/dev/null
rg -n "DylibInjection\\.removePath" "$CONTENT_VIEW" >/dev/null
rg -n "isDylibInjectionEnabled" "$CONTENT_VIEW" >/dev/null
rg -n "injectedDylibPaths: viewModel\\.isDylibInjectionEnabled \\? viewModel\\.injectedDylibPaths\\.map" "$CONTENT_VIEW" >/dev/null
