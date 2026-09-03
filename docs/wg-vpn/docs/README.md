# WG-VPN · WireGuard for HarmonyOS

> 基于 [WireGuard 白皮书](https://www.wireguard.com/papers/wireguard.pdf)，使用 **C++14** 跨平台重新实现的 HarmonyOS VPN 应用。

## 项目简介

**WG-VPN** 是一套面向 HarmonyOS 的 WireGuard 客户端。它不依赖官方 WireGuard 的 C / Go 实现，而是依照白皮书协议，使用可跨平台的 **C++14** 从零重新构建整条协议栈，让鸿蒙这样相对新兴的平台也能稳定、安全地接入 WireGuard 组网。

- **协议**：WireGuard（Noise 握手 + ChaCha20-Poly1305 加密）
- **语言**：C++14（截至开发时 HarmonyOS 最高支持 C++14）
- **平台**：HarmonyOS（Android 等端后续扩展开发中）
- **许可**：Apache-2.0 开源
- **作者**：CrazyLeojay（GitHub）

## 背景

官方 WireGuard 的实现对接入 HarmonyOS 并不友好：

- **C 实现**：大量依赖 Linux 内核方法，难以直接在鸿蒙上运行；
- **Go 实现**：缺乏对 HarmonyOS 的直接支持。

因此本项目抱着学习与开源的初衷，依据官方白皮书，用跨平台的 C++ 重新构建了 WireGuard 协议。项目同时维护了多分支（C++ 核心、HarmonyOS App、Android 等），各端共用一套底层协议库，便于后续跨平台拓展。

## 应用市场引导

WG-VPN 已上架**华为应用市场**，可直接搜索或点击下面的按钮安装。

[![华为应用市场](assets/appgallery.webp) 前往华为应用市场下载 WG-VPN](https://appgallery.huawei.com/app/detail?id=site.leojay.wireguard&channelId=SHARE&source=appshare)

- **应用名称**：WG-VPN
- **上架平台**：华为应用市场（HarmonyOS）
- **应用包名**：`site.leojay.wireguard`
- **访问链接**：[https://appgallery.huawei.com/app/detail?id=site.leojay.wireguard](https://appgallery.huawei.com/app/detail?id=site.leojay.wireguard&channelId=SHARE&source=appshare)

> 手机端可复制链接或直接扫码下载。安装后即可按 [使用指南](使用指南.md) 开始组网。

## 文档导航

| 文档 | 说明 |
| --- | --- |
| [使用指南](使用指南.md) | 从安装到组网的完整操作步骤（含截图） |
| [功能说明](功能说明.md) | 功能模块拆解与界面分析（含实机截图） |
| [意见反馈](意见反馈.md) | 问题反馈、需求建议与联系方式 |

## 重要声明

1. 本项目基于 **Apache-2.0** 协议开源，按“原样”提供，作者不对任何使用后果负责。
2. **禁止用于任何非法用途**（网络攻击、数据窃取、非法访问等），一切违法责任由使用者承担。
3. 建议用于合法网络测试、企业安全研究等合规场景。详见 [LEGAL_NOTICES](https://github.com/CrazyLeojay/cpplibrary-wireguard/blob/master/LEGAL_NOTICES.md)。

---

*本项目仅供学习与合规使用。使用即表示您已阅读并同意上述声明。*
