#include "logs.h"
#include "napi/native_api.h"
#include "WireGuardDevice.h"
#include "tools/conf_file.h"
#include "tools/wg_dns.h"
#include <hilog/log.h>
#include <memory>
#include <vector>

static napi_value NAPI_Global_makeKeyPair(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
//    napi_value ta;
//    napi_get_cb_info(env, info, nullptr, nullptr, &ta, nullptr);

        WireGuard::PrivateKey key;
        WireGuard::PublicKey pub;
        WireGuard::crypto::generatePrivateKey(key);
        WireGuard::crypto::generatePublicKey(pub, key);

        // interface KeyPair{
        //  privateKey:string;
        //  publicKey:string;
        //}
        napi_value result;
        ns = napi_create_object(env, &result);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto pkStr = WireGuard::crypto::bin32Array2Base64(key);

        std::string pkName = "privateKey";
        napi_value privateLabel;
        napi_value nvPrivate;
        ns = napi_create_string_utf8(env, pkName.data(), NAPI_AUTO_LENGTH, &privateLabel);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_create_string_utf8(env, pkStr.data(), NAPI_AUTO_LENGTH, &nvPrivate);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_property(env, result, privateLabel, nvPrivate);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto pubKStr = WireGuard::crypto::bin32Array2Base64(pub);
        std::string pubName = "publicKey";
        napi_value publicLabel;
        napi_value nvPublic;
        ns = napi_create_string_utf8(env, pubName.data(), NAPI_AUTO_LENGTH, &publicLabel);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_create_string_utf8(env, pubKStr.data(), NAPI_AUTO_LENGTH, &nvPublic);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_property(env, result, publicLabel, nvPublic);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        return result;

    } catch (const std::exception &e) {
        napi_throw_error(env, "生成密钥对", e.what());
        return nullptr;
    }
}

static napi_value NAPI_Global_genPrivateKey(napi_env env, napi_callback_info info) {

    try {
        napi_status ns;
        WireGuard::PrivateKey key;
        WireGuard::crypto::generatePrivateKey(key);

        auto pkStr = WireGuard::crypto::bin32Array2Base64(key);

        napi_value nvPrivate;
        ns = napi_create_string_utf8(env, pkStr.data(), NAPI_AUTO_LENGTH, &nvPrivate);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        return nvPrivate;
    } catch (const std::exception &e) {
        napi_throw_error(env, "获取私钥", e.what());
        return nullptr;
    }
}

static napi_value NAPI_Global_genPublicKey(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        napi_value nvPublic;
        size_t argc = 1;
        napi_value args[argc];
        napi_value arkTs;
        ns = napi_get_cb_info(env, info, &argc, args, &arkTs, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        size_t len;
        ns = napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        std::vector<char> buf(len + 1);
        ns = napi_get_value_string_utf8(env, args[0], buf.data(), len + 1, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        WireGuard::PrivateKey privateKey = WireGuard::crypto::base642Bin32Array(std::string(buf.data(), len));
        WireGuard::PublicKey pub;
        WireGuard::crypto::generatePublicKey(pub, privateKey);

        auto pubKStr = WireGuard::crypto::bin32Array2Base64(pub);
        ns = napi_create_string_utf8(env, pubKStr.data(), NAPI_AUTO_LENGTH, &nvPublic);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        return nvPublic;
    } catch (const std::exception &e) {
        napi_throw_error(env, "获取公钥", e.what());
        return nullptr;
    }
}

static napi_value NAPI_Global_readWGConf(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        size_t len;
        ns = napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        std::vector<char> buf(len + 1);
        ns = napi_get_value_string_utf8(env, args[0], buf.data(), len + 1, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        WireGuard::Tools::WGConf entity = WireGuard::Tools::readConfFileToEntity(std::string(buf.data(), len));
        return NapiTools::createNvForWGConf(env, entity);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}


static napi_value NAPI_Global_isIpv4(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "isIPv4参数");
        bool result = WireGuard::Tools::isIPv4(nvContent);

        return NapiTools::makeNapiBool(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}

static napi_value NAPI_Global_isIpv6(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "isIPv6参数");
        bool result = WireGuard::Tools::isIPv6(nvContent);

        return NapiTools::makeNapiBool(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}
static napi_value NAPI_Global_isIpAddress(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "isIpAddress参数");
        bool result = WireGuard::Tools::isValidIPAddress(nvContent);

        return NapiTools::makeNapiBool(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}

static napi_value NAPI_Global_isValidDomain(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "isValidDomain参数");
        bool result = WireGuard::Tools::isValidDomain(nvContent);

        return NapiTools::makeNapiBool(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}
static napi_value NAPI_Global_isValidBase64Key(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "isValidBase64Key参数");
        bool result = WireGuard::Tools::isValidBase64Key(nvContent);

        return NapiTools::makeNapiBool(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}
// 将域名转为IP，优先IPv4，失败则尝试IPv6
static napi_value NAPI_Global_dnsToIp(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "dnsToIp参数");
        LOG_INFO("dnsToIp: domain=%{public}s", nvContent.c_str());
        auto ip = WireGuard::DNS::readDomainToIpPreferIpv4(nvContent);
        auto ipStr = ip.toIpStr();
        LOG_INFO("dnsToIp: resolved=%{public}s", ipStr.c_str());
        return NapiTools::makeNapiString(env, ipStr);
    } catch (const std::exception &e) {
        LOG_ERROR("dnsToIp failed: %{public}s", e.what());
        std::string errMsg = "dnsToIp: " + std::string(e.what());
        napi_throw_error(env, nullptr, errMsg.c_str());
        return nullptr;
    }
}

// 将域名转为指定类型的IP（type: 4=IPv4, 6=IPv6）
static napi_value NAPI_Global_dnsToIpWithType(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 2;
        napi_value args[2];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        auto nvContent = NapiTools::napiGetString(env, args[0], "dnsToIpWithType参数");
        int32_t typeVal;
        ns = napi_get_value_int32(env, args[1], &typeVal);
        if (ns != napi_ok) {
            throw WireGuard::WGException("获取type参数失败");
        }
        auto ipType = static_cast<WireGuard::DNS::IPType>(typeVal);
        LOG_INFO("dnsToIpWithType: domain=%{public}s, type=%{public}d", nvContent.c_str(), typeVal);
        auto ip = WireGuard::DNS::readDomainToIp(nvContent, ipType);
        auto ipStr = ip.toIpStr();
        LOG_INFO("dnsToIpWithType: resolved=%{public}s", ipStr.c_str());
        return NapiTools::makeNapiString(env, ipStr);
    } catch (const std::exception &e) {
        LOG_ERROR("dnsToIpWithType failed: %{public}s", e.what());
        std::string errMsg = "dnsToIpWithType: " + std::string(e.what());
        napi_throw_error(env, nullptr, errMsg.c_str());
        return nullptr;
    }
}

static napi_value NAPI_Global_wgToOfficialStr(napi_env env, napi_callback_info info) {
    try {
        napi_status ns;
        size_t argc = 1;
        napi_value args[argc];
        ns = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        auto entity = NapiTools::napiGetWGConf2Entity(env, args[0]);
        auto result = WireGuard::Tools::wgConfToOfficialConfigStr(entity);
        return NapiTools::makeNapiString(env, result);
    } catch (const std::exception &e) {
        napi_throw_error(env, "读取异常", e.what());
        return nullptr;
    }
}
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    wg_napi::Init(env, exports);
    napi_property_descriptor desc[] = {
        {        "makeKeyPair", nullptr,      NAPI_Global_makeKeyPair, nullptr, nullptr, nullptr, napi_default, nullptr},
        {      "genPrivateKey", nullptr,    NAPI_Global_genPrivateKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {       "genPublicKey", nullptr,     NAPI_Global_genPublicKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {         "readWGConf", nullptr,       NAPI_Global_readWGConf, nullptr, nullptr, nullptr, napi_default, nullptr},
        {             "isIpv4", nullptr,           NAPI_Global_isIpv4, nullptr, nullptr, nullptr, napi_default, nullptr},
        {             "isIpv6", nullptr,           NAPI_Global_isIpv6, nullptr, nullptr, nullptr, napi_default, nullptr},
        {        "isIpAddress", nullptr,      NAPI_Global_isIpAddress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {      "isValidDomain", nullptr,    NAPI_Global_isValidDomain, nullptr, nullptr, nullptr, napi_default, nullptr},
        {   "isValidBase64Key", nullptr, NAPI_Global_isValidBase64Key, nullptr, nullptr, nullptr, napi_default, nullptr},
        {            "dnsToIp", nullptr,          NAPI_Global_dnsToIp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {    "dnsToIpWithType", nullptr,  NAPI_Global_dnsToIpWithType, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"wgConfToOfficialStr", nullptr,  NAPI_Global_wgToOfficialStr, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "wg_tunnel",
    .nm_priv = ((void *) 0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTunnelModule(void) { napi_module_register(&demoModule); }
