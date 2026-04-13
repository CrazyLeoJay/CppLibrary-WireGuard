#include "napi/native_api.h"
#include "WireGuardDevice.h"
#include <cstdint>

static napi_value Add(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};

    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_valuetype valuetype0;
    napi_typeof(env, args[0], &valuetype0);

    napi_valuetype valuetype1;
    napi_typeof(env, args[1], &valuetype1);

    double value0;
    napi_get_value_double(env, args[0], &value0);

    double value1;
    napi_get_value_double(env, args[1], &value1);

    napi_value sum;
    napi_create_double(env, value0 + value1, &sum);

    return sum;
}

static napi_value MakeKeyPair(napi_env env, napi_callback_info info) {
    try {
//    napi_value ta;
//    napi_get_cb_info(env, info, nullptr, nullptr, &ta, nullptr);

        WireGuard::PrivateKey key;
        WireGuard::PublicKey pub;
        WireGuard::Crypto::generatePrivateKey(key);
        WireGuard::Crypto::generatePublicKey(pub, key);

        // interface KeyPair{
        //  privateKey:string;
        //  publicKey:string;
        //}
        napi_value result;
        napi_create_object(env, &result);

        auto pkStr = WireGuard::Crypto::bin32Array2Base64(key);

        std::string pkName = "privateKey";
        napi_value privateLabel;
        napi_value nvPrivate;
        napi_create_string_utf8(env, pkName.data(), NAPI_AUTO_LENGTH, &privateLabel);
        napi_create_string_utf8(env, pkStr.data(), NAPI_AUTO_LENGTH, &nvPrivate);
        napi_set_property(env, result, privateLabel, nvPrivate);

        auto pubKStr = WireGuard::Crypto::bin32Array2Base64(pub);
        std::string pubName = "publicKey";
        napi_value publicLabel;
        napi_value nvPublic;
        napi_create_string_utf8(env, pubName.data(), NAPI_AUTO_LENGTH, &publicLabel);
        napi_create_string_utf8(env, pubKStr.data(), NAPI_AUTO_LENGTH, &nvPublic);
        napi_set_property(env, result, publicLabel, nvPublic);

        return result;

    } catch (const std::exception &e) {
        napi_throw_error(env, "生成密钥对", e.what());
        return nullptr;
    }
}

static napi_value GenPrivateKey(napi_env env, napi_callback_info info) {

    try {
        WireGuard::PrivateKey key;
        WireGuard::Crypto::generatePrivateKey(key);

        auto pkStr = WireGuard::Crypto::bin32Array2Base64(key);

        napi_value nvPrivate;
        napi_create_string_utf8(env, pkStr.data(), NAPI_AUTO_LENGTH, &nvPrivate);
        return nvPrivate;
    } catch (const std::exception &e) {
        napi_throw_error(env, "获取私钥", e.what());
        return nullptr;
    }
}

static napi_value GenPublicKey(napi_env env, napi_callback_info info) {
    try {
        napi_value nvPublic;
        size_t argc = 1;
        napi_value args[argc];
        napi_value arkTs;
        napi_get_cb_info(env, info, &argc, args, &arkTs, nullptr);

        size_t len;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        char *buf = new char[len + 1];
        napi_get_value_string_utf8(env, args[0], buf, len + 1, &len);

        WireGuard::PrivateKey privateKey = WireGuard::Crypto::base642Bin32Array(std::string(buf, len));
        WireGuard::PublicKey pub;
        WireGuard::Crypto::generatePublicKey(pub, privateKey);

        auto pubKStr = WireGuard::Crypto::bin32Array2Base64(pub);
        napi_create_string_utf8(env, pubKStr.data(), NAPI_AUTO_LENGTH, &nvPublic);
        return nvPublic;
    } catch (const std::exception &e) {
        napi_throw_error(env, "获取公钥", e.what());
        return nullptr;
    }
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    wg_napi::Init(env, exports);
    napi_property_descriptor desc[] = {
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"makeKeyPair", nullptr, MakeKeyPair, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"genPrivateKey", nullptr, GenPrivateKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"genPublicKey", nullptr, GenPublicKey, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 4, desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "wg_tunnel",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTunnelModule(void) { napi_module_register(&demoModule); }
