#include "ZSignMachOInjector.h"

#include "common.h"
#include "macho.h"

bool ZSignInjectDylibs(const std::string& executablePath,
                       const std::vector<std::string>& dylibNames,
                       bool weakInject,
                       std::string& errorMessage)
{
    ZMachO macho;
    if (!macho.Init(executablePath.c_str())) {
        errorMessage = "zsign 无法解析主可执行文件";
        return false;
    }

    for (const std::string& dylibName : dylibNames) {
        if (!macho.InjectDylib(weakInject, dylibName.c_str())) {
            errorMessage = "zsign 注入动态库失败：" + dylibName;
            macho.Free();
            return false;
        }
    }

    if (!macho.Free()) {
        errorMessage = "zsign 写回主可执行文件失败";
        return false;
    }

    return true;
}
