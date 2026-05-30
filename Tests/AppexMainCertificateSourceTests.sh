#!/bin/sh
set -eu

RESIGN_TASK="EasySign/ResignService/Model/ResignTask.swift"
README="README.md"
ZSIGN_DOC="docs/zsign-backend.md"

rg -n "codesignAppex\\(appBundle: appBundle, pkcs12: pkcs12, mobileProvision: mobileProvision, logger: logger\\)" "$RESIGN_TASK" >/dev/null
rg -n "private func codesignAppex\\(appBundle: AppBundle, pkcs12: PKCS12, mobileProvision: MobileProvision, logger: LoggerProtocol\\?\\)" "$RESIGN_TASK" >/dev/null
rg -n "使用主 App 证书重签" "$RESIGN_TASK" >/dev/null
rg -n "zsign 将使用主 App 证书和描述文件递归重签 Appex" "$RESIGN_TASK" >/dev/null
rg -n "Appex.*主 App 证书" "$README" "$ZSIGN_DOC" >/dev/null

if rg -n "taskInfo\\.appexResignInfos|独立 Appex 证书配置|单独对 App Extension|使用不同证书|指定证书重签名" "$RESIGN_TASK" "$README" "$ZSIGN_DOC" >/dev/null; then
  exit 1
fi

if rg -n "appexResignInfos|AppexResignInfo" EasySign -g '!Vendor/**' >/dev/null; then
  exit 1
fi
