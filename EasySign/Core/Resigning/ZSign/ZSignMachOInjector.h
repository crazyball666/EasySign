#pragma once

#include <string>
#include <vector>

bool ZSignInjectDylibs(const std::string& executablePath,
                       const std::vector<std::string>& dylibNames,
                       bool weakInject,
                       std::string& errorMessage);
