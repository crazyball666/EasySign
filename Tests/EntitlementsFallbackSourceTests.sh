#!/bin/sh
set -eu

RESIGN_TASK="EasySign/ResignService/Model/ResignTask.swift"

rg -n "解析自定义 entitlements" "$RESIGN_TASK" >/dev/null
rg -n "读取原 entitlements 失败，改用描述文件 entitlements 作为基底" "$RESIGN_TASK" >/dev/null
rg -n "newEntitlements = mobileProvision\\.entitlements" "$RESIGN_TASK" >/dev/null

if rg -n "var newEntitlements = try appBundle\\.getEntitlements\\(\\)" "$RESIGN_TASK" >/dev/null; then
  exit 1
fi
