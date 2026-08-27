# WireGuard VPN C++实现

> 本项目基于 WireGuard白皮书协议规定，重新使用C++实现功能，用于跨平台开发
>
> 由于Harmonyos相对于WireGuard是新兴起的平台，截至本项目开发前，应用市场并没有此类软件。
>
> 虽然官方建议使用go进行跨平台接入，但WireGuard的c、go实现，对接入Harmonyos没有很好的支持
>
> - c实现使用了很多linux内核方法
> - go没有直接的支持。
>
> （也有可能是才疏学浅，没有发现）
>
> 所以抱着学习的态度，根据官方白皮书重新使用c++，所有实现都使用跨平台方式来重新构建了WireGuard。

**使用C++14，因为截至开发为止，harmonyos最高支持C++14**

计划实现下述途径使用：

- [x] HarmonyOs App
- [ ] Android app

其他端开发完善后再考虑，不过我有很多设想，以待后续拓展。



## ⚠️ **重要声明（请务必阅读）**

**本项目基于 Apache-2.0 协议开源，按“原样”提供，无担保，作者不对任何使用后果负责（详见** [ LICENSE ](LICENSE)**）。**

1. **禁止非法用途**：严禁用于违反中国法律法规的行为（如网络攻击、数据窃取、非法访问等），一切违法责任由使用者承担。

2. **合规使用**：建议用于合法网络测试、企业安全研究等合规场景。

3. **完整条款**：详见 [ LEGAL_NOTICES.md ](LEGAL_NOTICES.md) 文件。

**免责申明**：用户须自行承担使用风险，作者不对数据丢失、系统问题或违法使用导致的后果负责。



---

## 开发进度

- [x] 基本通讯
  - [x] IP 的 CIDR 索引树（CIDR tree）
  - [x] Noise握手和响应
  - [x] 数据加密传输
  - [x] UDP Socket 通讯
  - [x] 基础接收端和发送端搭建（device类，用于NDK映射）
- [x] Cookie 挑战



## 分支管理

> master-* 这里是正对不同的开发目标定制的开发环境。使用 git worktree 进行环境隔离开发。

| 描述             | 分支名称            | 文档                               | 注释                                                         |
| ---------------- | ------------------- | ---------------------------------- | ------------------------------------------------------------ |
| 集合展示主页     | master              | [README](docs/README.md)           | 项目主页，用于对外展示，<br />合并所有`master-*`分支的代码集合 |
| 主要功能开发分支 | master-cpp          | [README](docs/cpp/README.md)       | WireGuard主要实现功能                                        |
| HarmonyOS App    | master-harmonyos    | [README](docs/harmonyos/README.md) | HarmonyOS App app应用开发                                    |
| Android App      | master-android-dev  | [README](docs/android/README.md)   | Android App 应用开发                                         |
| React Native     | master-react-native | [README](docs/react/README.md)     | React native 客户端，属于学习模块                            |
| KMP              | master-kmp          | [README](docs/kmp/README.md)       | KMP 跨平台模块，属于学习模块                                 |

> 注：有些文档可能还没完善，先占个位，减少合并冲突。
>
> 学习模块：学习模块是为了学习框架使用，不会保证最新更新。

## 版本管理

> 这里做一个版本管理示例
>
> 根据实际开发情况，版本号应该不会保持一致，根据实际开发决定。

| 主要开发分支       | 版本   | 标签           |
| ------------------ | ------ | -------------- |
| master-cpp         | v1.0.0 | native-v1.0.0  |
| master-harmonyos   | v1.0.0 | harmony-v1.0.0 |
| master-android-dev | v1.0.0 | android-v1.0.0 |



## 文献

- [WireGuard 官网](https://www.wireguard.com/)
- [WireGuard 白皮书](https://www.wireguard.com/papers/wireguard.pdf)
- [WireGuard 协议说明](https://www.wireguard.com/protocol/)



## 支持

如果觉得app或者项目好用，可以请作者喝杯咖啡。您的支持是我更新的动力

<p align="center">
<img src="README.assets/33f42378afa2d0d7eae662c08c4348d3.jpg" alt="33f42378afa2d0d7eae662c08c4348d3" alt="Alipay" width="300" /><img src="README.assets/4941d4083266371ac9f713c61fa944f4.png" alt="4941d4083266371ac9f713c61fa944f4" alt="WeChat Pay" width="300" />
</p>



