#!/bin/sh
set -eu

if rg -n "optool|resign_tools" EasySign/ResignService/Model/ResignTask.swift docs/zsign-backend.md README.md CLAUDE.md >/tmp/easysign-optool-references.txt; then
  cat /tmp/easysign-optool-references.txt >&2
  echo "系统 codesign 后端的动态库注入不应再依赖 optool" >&2
  exit 1
fi

if [ -e EasySign/Resources/resign_tools/optool ]; then
  echo "未使用的 optool 二进制不应继续打包到 App 资源中" >&2
  exit 1
fi

rg -n "injectDylibs" EasySign/ResignService/ZSign/ZSignBridge.h >/dev/null
rg -n "ZSignInjectDylibs" EasySign/ResignService/ZSign/ZSignBridge.mm >/dev/null
rg -n "#include \"macho.h\"" EasySign/ResignService/ZSign/ZSignMachOInjector.cpp >/dev/null
rg -n "macho\\.Free\\(\\)" EasySign/ResignService/ZSign/ZSignMachOInjector.cpp >/dev/null
