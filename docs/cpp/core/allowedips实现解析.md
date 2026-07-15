# AllowedIPs 实现解析

## 概述

`AllowedIPs` 是 WireGuard 协议的核心组件之一，用于实现 IP 地址前缀路由表。它的主要作用是：

- **维护允许的 IP 地址范围**：存储每个 Peer（对端）允许通信的 IP 地址前缀（CIDR 格式）
- **快速查找路由**：根据数据包的目标 IP 或源 IP 快速找到对应的 Peer
- **支持 IPv4 和 IPv6**：分别维护两个独立的 Trie 树（前缀树）
- **并发访问安全**：使用互斥锁保护 Trie 树的读写操作

该模块使用 Trie 树（前缀树）数据结构来存储 IP 前缀，支持高效的插入、删除和查找操作。查找时采用**最长前缀匹配**算法，确保返回最精确的路由规则。

---

## 数据结构设计

### TrieNode 节点结构

```cpp
struct TrieNode {
    std::weak_ptr<Peer> peer;           // 关联的 Peer 弱引用（避免循环引用）
    mutable std::unique_ptr<TrieNode> child[2];  // 左右子节点（0 和 1）
    uint32_t cidr = 0;                  // 前缀长度（CIDR 值，如 /24, /32）
    std::vector<uint8_t> bits{};        // IP 地址的二进制表示（网络字节序）
};
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `peer` | `weak_ptr<Peer>` | 关联的 Peer，为空表示这是一个中间节点 |
| `child[0/1]` | `unique_ptr<TrieNode>` | 两个子节点，根据下一位的值（0 或 1）决定 |
| `cidr` | `uint32_t` | CIDR 前缀长度，特殊值 `255` 表示根节点 |
| `bits` | `vector<uint8_t>` | IP 地址的二进制字节表示（IPv4=4 字节，IPv6=16 字节） |

### AllowedIPs 类结构

```cpp
class AllowedIPs {
private:
    std::unique_ptr<TrieNode> ipv4Root{};  // IPv4 Trie 树根节点
    std::unique_ptr<TrieNode> ipv6Root{};  // IPv6 Trie 树根节点
    mutable std::mutex mutex;              // 读写互斥锁
};
```

---

## 核心实现流程

### 1. 初始化

调用 `clear()` 方法创建两个根节点：

```cpp
void AllowedIPs::clear() {
    ipv4Root = std::make_unique<TrieNode>();
    ipv4Root->setRoot(IPAddress::IPv4);  // cidr=255, bits=4个0
    ipv6Root = std::make_unique<TrieNode>();
    ipv6Root->setRoot(IPAddress::IPv6);  // cidr=255, bits=16个0
}
```

### 2. 添加路由规则

调用 `addPeer()` 方法将 Peer 的所有允许 IP 地址前缀添加到路由表中：

```
流程：
┌─────────────────────────────────────────────────────────────┐
│  addPeer(peer)                                             │
│  ├─ 获取 peer->allowedIps 列表                             │
│  ├─ 遍历每个 IpAddressArea                                 │
│  │   ├─ IPv4: applyMask(ip, cidr) → maskedIp              │
│  │   │   └─ insertTrieNode(ipv4Root, maskedIp, ...)       │
│  │   └─ IPv6: applyMask(ip, cidr) → maskedIp              │
│  │       └─ insertTrieNode(ipv6Root, maskedIp, ...)       │
│  └─ 返回                                                   │
└─────────────────────────────────────────────────────────────┘
```

**掩码处理**（关键步骤）：

```cpp
void applyMask(const uint8_t *ip, size_t ipLen, uint32_t cidr, uint8_t *result) {
    // 将 IP 地址按 CIDR 掩码处理，只保留网络位
    // 例如：10.0.0.1/24 → 10.0.0.0（后8位清零）
}
```

### 3. 插入 Trie 节点

`insertTrieNode()` 是核心插入函数，处理以下四种情况：

```
┌─────────────────────────────────────────────────────────────────────┐
│  insertTrieNode(index, ip, cidr, peer)                            │
│                                                                     │
│  ① 检查当前节点是否完全匹配（IP + CIDR）                            │
│     └─ 如果匹配 → 更新 peer 引用，返回                             │
│                                                                     │
│  ② 检查子节点是否是父节点（cidr更小且前缀匹配）                      │
│     └─ 如果是 → 递归插入到子节点                                   │
│                                                                     │
│  ③ 子节点不存在                                                   │
│     └─ 直接创建新节点作为子节点                                     │
│                                                                     │
│  ④ 子节点存在但不是父节点                                          │
│     ├─ 计算公共前缀 common                                          │
│     ├─ common < min(newCidr, nextCidr)                            │
│     │   └─ 创建中间节点，将两者作为其子节点                         │
│     ├─ 新节点是父节点                                              │
│     │   └─ 将子节点挂到新节点下                                    │
│     └─ 否则                                                       │
│         └─ 递归插入到子节点                                        │
└─────────────────────────────────────────────────────────────────────┘
```

### 4. 查找 Peer

`findPeer()` 和 `findPeerForNodeTree()` 实现最长前缀匹配查找：

```
┌─────────────────────────────────────────────────────────────────────┐
│  findPeerForNodeTree(index, ip, len)                              │
│                                                                     │
│  ① 当前节点为空 → 返回 nullptr                                     │
│                                                                     │
│  ② 根据 IP 地址的当前位选择子节点                                   │
│                                                                     │
│  ③ 深度优先搜索：优先查找子节点                                     │
│     └─ 如果子节点有匹配结果 → 直接返回（保证最长前缀匹配）           │
│                                                                     │
│  ④ 子节点没有匹配，检查当前节点                                     │
│     ├─ 根节点 → 跳过                                               │
│     └─ 非根节点                                                    │
│         ├─ IP 匹配前缀 且 peer 不为空 → 返回 peer                   │
│         └─ 否则 → 返回 nullptr                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Trie 树结构示例

### 插入路由规则后的树结构

假设插入以下路由：
- `10.0.0.0/24` → Peer A
- `10.1.0.0/24` → Peer B
- `192.168.1.0/24` → Peer C
- `192.168.1.5/32` → Peer D

最终树结构：

```
                              ┌──────────────┐
                              │    Root      │ ← cidr=255, peer=null
                              └──────────────┘
                                      │
                      ┌───────────────┴───────────────┐
                      ▼                               ▼
               ┌─────────────┐                  ┌─────────────┐
               │    cidr=8   │ ← 自动创建       │    cidr=8   │ ← 自动创建
               │   10.x.x.x  │                  │  192.x.x.x  │
               │   peer=null │                  │   peer=null │
               └─────────────┘                  └─────────────┘
                       │                               │
           ┌───────────┴───────────┐           ┌───────┴───────┐
           ▼                       ▼           ▼               ▼
      ┌───────────┐         ┌───────────┐ ┌───────────┐   ┌───────────┐
      │ 10.0.0.0/24│         │ 10.1.0.0/24│ │ 192.168.1.0/24│   │ 其他      │
      │   Peer A  │         │   Peer B  │ │   Peer C  │   │ 子网      │
      └───────────┘         └───────────┘ └───────────┘   └───────────┘
                                              │
                                      ┌───────┴───────┐
                                      ▼               ▼
                                 ┌───────────┐   ┌───────────┐
                                 │192.168.1.5/32│   │ 其他      │
                                 │   Peer D  │   │ 主机      │
                                 └───────────┘   └───────────┘
                                      │
                                 ┌────┴────┐
                                 ▼         ▼
                              null      null ← 叶子节点
```

### 节点层级特点

| 层级 | 节点类型 | CIDR 特点 | Peer 特点 | 作用 |
|------|----------|-----------|-----------|------|
| **顶端（根）** | 根节点 | 255（特殊值） | ❌ 无 | 入口，根据最高位分流 |
| **上层（公共前缀）** | 自动创建 | 较小（如 7, 8） | ❌ 无 | 路由分支点，引导方向 |
| **中层（路由规则）** | 用户配置 | 中等（如 16, 24） | ✅ 有 | 实际匹配规则 |
| **底层（叶子）** | 用户配置 | 最大（32/128） | ✅ 有 | 具体主机匹配 |

---

## 本次修改关键内容

### 修改1：修复 Trie 树插入逻辑

**问题**：当插入两个 CIDR 相同但 IP 不同的节点时（如 `10.0.0.0/24` 和 `10.1.0.0/24`），原代码直接将现有节点作为新节点的子节点，导致 Trie 退化为链表，查找时 `chooseBit` 会走错分支。

**修复方案**：计算两个节点的公共前缀，当公共前缀小于两者的 CIDR 时，创建中间节点。

**修改位置**：[allowedips.cpp:198-215](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp#L198-L215)

### 修改2：添加 IP 地址掩码处理

**问题**：原代码直接存储完整的 IP 地址，没有进行掩码处理。例如 `10.0.0.1/24` 和 `10.0.0.2/24` 会被当作不同的路由规则，但它们实际上指向同一个网络。

**修复方案**：插入前对 IP 地址进行掩码处理，只保留网络位。

**修改位置**：[allowedips.cpp:51-66](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp#L51-L66)

### 修改3：修复枚举值重复

**问题**：`PacketIpType` 枚举中 `IPV4` 和 `IPV6` 都等于 0，导致无法正确区分。

**修复方案**：`IPV4 = 4`, `IPV6 = 6`

**修改位置**：[entity.h:143-146](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/entity.h#L143-L146)

### 修改4：修复 IPv6 包长度校验边界

**问题**：IPv6 包长度校验使用 `len <= sizeof(IPv6Hdr)`，导致恰好 40 字节的合法 IPv6 包被错误拒绝。

**修复方案**：改为 `len < sizeof(IPv6Hdr)`

**修改位置**：[tools.cpp:167](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/tools.cpp#L167)

### 修改5：修复子节点完全匹配检查缺失

**问题**：`insertTrieNode` 中完全匹配检查（IP + CIDR 相同则更新 peer）只作用于当前节点 `index`，而不作用于子节点 `next`。当插入一个与现有子节点完全相同的路由规则时，代码不会更新 `next` 的 peer，而是走到公共前缀计算分支，导致重复节点创建和错误的查找结果。

**修复方案**：在子节点存在的分支里，在 `isParent` 检查之前，增加对 `next` 的完全匹配检查。

**修改位置**：[allowedips.cpp:188-197](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp#L188-L197)

### 修改6：修复中间节点 IP 掩码处理

**问题**：中间节点的 `bits` 字段直接复制了新节点的完整 IP，未按 `common` 位进行掩码清零，虽然不影响 `prefixMatches` 和 `chooseBit` 的正确性，但不符合数据一致性原则，可能在后续维护中造成混淆。

**修复方案**：在中间节点创建处，对 `intermediate->bits` 按 `common` 位进行掩码处理，调用 `applyMask(ip, ipLen, common, intermediate->bits.data())` 替代直接 `memcpy`。

**修改位置**：[allowedips.cpp:228-229](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp#L228-L229)

---

## Q&A 深度剖析

### Q1：中间节点的 IP 是多少？会不会匹配到但 Peer 为空？

**A**：中间节点的 IP 是经过掩码处理后的网络地址，只保留前 `common` 位。例如：

- 新节点：`10.1.0.0/24`
- 现有节点：`10.0.0.0/24`
- 公共前缀：7 位
- 中间节点：`10.0.0.0/7`（IP 经过 `applyMask(ip, ipLen, 7, ...)` 处理，只保留前7位）

**不会匹配到中间节点返回错误**，因为查找逻辑有双重保护：

1. **深度优先搜索**：先递归查找子节点，如果子节点有匹配结果就直接返回，不会检查当前节点。
2. **Peer 空检查**：只有当 `prefixMatches(ip)` 且 `peer.lock()` 不为空时才返回结果。中间节点的 `peer` 为空（默认空 `weak_ptr`），所以即使 IP 匹配也会返回 `nullptr`。

### Q2：如果输入 `10.0.0.1/24` 和 `10.0.0.2/24`，会冲突还是覆盖？

**A**：经过掩码处理后，它们都会转换为 `10.0.0.0/24`，所以会被识别为同一个路由规则，后添加的 Peer 会覆盖先添加的 Peer。

**关键代码**：完全匹配检查需要同时覆盖当前节点和子节点：

```cpp
// allowedips.cpp:174-181 - 检查当前节点
if (!index->isRoot()) {
    if (index->cidr == cidr && index->bits.size() == ipLen) {
        if (std::memcmp(index->bits.data(), ip, ipLen) == 0) {
            index->peer = peer;
            return;
        }
    }
}

// allowedips.cpp:188-197 - 检查子节点
if (next) {
    if (next->cidr == cidr && next->bits.size() == ipLen) {
        if (std::memcmp(next->bits.data(), ip, ipLen) == 0) {
            next->peer = peer;  // 直接覆盖！
            return;
        }
    }
}
```

这样才能确保无论路由规则存储在哪个层级的节点，重复插入时都能正确更新 Peer。

### Q3：中间节点有可能被赋予 Peer 吗？

**A**：有可能！有两种情况：

1. **自动创建的公共前缀节点**：没有 Peer（代码不设置 `peer`）。
2. **用户配置的大 CIDR 节点**：有 Peer。例如用户配置了 `10.0.0.0/8` → Peer A 和 `10.0.0.0/24` → Peer B，那么 `10.0.0.0/8` 就是一个有 Peer 的中间节点。

查找 `10.0.0.100` 时会返回 Peer B（最长前缀匹配），因为深度优先搜索会优先返回更深层的匹配结果。

### Q4：为什么需要维护两个独立的 Trie 树（IPv4 和 IPv6）？

**A**：主要原因是 IPv4（4 字节）和 IPv6（16 字节）的地址长度不同，如果放在同一个树中会导致：

1. **空间浪费**：IPv4 节点的 `bits` 需要预留 16 字节空间。
2. **查找效率降低**：每次查找都需要处理更长的地址。
3. **逻辑复杂**：需要额外判断地址类型，增加代码复杂度。

### Q5：为什么使用 `weak_ptr<Peer>` 而不是 `shared_ptr<Peer>`？

**A**：避免循环引用。`Peer` 对象内部可能持有 `AllowedIPs` 的引用，如果 `TrieNode` 使用 `shared_ptr<Peer>`，会形成循环引用，导致内存泄漏。使用 `weak_ptr` 可以打破循环，让引用计数正确递减。

### Q6：`chooseBit` 函数是如何工作的？

**A**：`chooseBit` 根据当前节点的 CIDR 值，计算下一位应该走哪个子节点：

```cpp
uint8_t chooseBit(const uint8_t *ip, const size_t len) const {
    uint8_t bitAtByte = cidr / 8;        // 当前位所在的字节索引
    uint8_t bitAtShift = 7 - (cidr % 8); // 位在字节中的偏移
    return (ip[bitAtByte] >> bitAtShift) & 1;
}
```

例如，当前节点 CIDR=24：
- `bitAtByte = 24 / 8 = 3`（第4个字节）
- `bitAtShift = 7 - (24 % 8) = 7`（最高位）
- 返回 IP 第4个字节的最高位（0 或 1）

### Q7：`prefixMatches` 函数如何判断 IP 是否匹配前缀？

**A**：通过计算两个 IP 地址的公共前缀位数，如果公共前缀位数 >= 节点的 CIDR，说明匹配：

```cpp
bool prefixMatches(const TrieNode *node, const uint8_t *ip) {
    size_t len = node->bits.size();
    uint8_t common = commonBits(node->bits.data(), ip, len);
    return common >= node->cidr;
}
```

`commonBits` 逐字节异或，统计高位连续相同的位数。

---

## 流程图汇总

### 插入流程

```
┌─────────────────────────────────────────────────────────────┐
│                      addPeer(peer)                          │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              遍历 peer->allowedIps                          │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
   IPv4 地址                        IPv6 地址
        │                               │
        ▼                               ▼
┌─────────────────────┐      ┌─────────────────────┐
│  applyMask(ip, cidr)│      │  applyMask(ip, cidr)│
│  → maskedIp         │      │  → maskedIp         │
└───────────┬─────────┘      └───────────┬─────────┘
            │                            │
            ▼                            ▼
┌─────────────────────────────────────────────────────────────┐
│              insertTrieNode(root, maskedIp, cidr, peer)     │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   完全匹配？        子节点是父节点？  子节点不存在？
        │               │               │
        ▼               ▼               ▼
   更新 peer      递归插入到子节点   创建新节点
        │               │               │
        └───────────────┴───────────────┘
                        │
                        ▼
              计算公共前缀 common
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   common <       新节点是父节点？    递归插入
   min(cidr)?          │               │
        │               ▼               │
        ▼         子节点挂到新节点下     │
   创建中间节点              │           │
        │                   │           │
        └───────────────────┴───────────┘
```

### 查找流程

```
┌─────────────────────────────────────────────────────────────┐
│                   findPeer(address)                         │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
   IPv4 地址                        IPv6 地址
        │                               │
        └───────────────┬───────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              findPeerForNodeTree(root, ip, len)             │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
              ┌───────────────────┐
              │   index 为空？    │
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
            Yes                 No
              │                   │
              ▼                   ▼
         返回 nullptr     根据当前位选择子节点
                        │
                        ▼
              ┌───────────────────┐
              │   子节点存在？    │
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
            Yes                 No
              │                   │
              ▼                   ▼
      递归查找子节点         检查当前节点
              │                   │
              ▼                   ▼
      ┌─────────────┐      ┌─────────────┐
      │ 有匹配结果？ │      │ 是根节点？  │
      └──────┬──────┘      └──────┬──────┘
             │                    │
      ┌──────┴──────┐      ┌──────┴──────┐
      ▼             ▼      ▼             ▼
    Yes           No      Yes           No
      │             │      │             │
      ▼             ▼      ▼             ▼
  返回结果    检查当前节点  返回 nullptr  前缀匹配？
                    │                       │
                    ▼                       ▼
           ┌─────────────┐       ┌─────────────┐
           │ 是根节点？  │       │ 有 Peer？   │
           └──────┬──────┘       └──────┬──────┘
                  │                    │
           ┌──────┴──────┐       ┌──────┴──────┐
           ▼             ▼       ▼             ▼
         Yes           No       Yes           No
           │             │       │             │
           ▼             ▼       ▼             ▼
      返回 nullptr   前缀匹配？ 返回 Peer    返回 nullptr
                       │
                       ▼
              ┌─────────────┐
              │ 有 Peer？   │
              └──────┬──────┘
                     │
              ┌──────┴──────┐
              ▼             ▼
            Yes           No
              │             │
              ▼             ▼
          返回 Peer    返回 nullptr
```

---

## 核心代码索引

| 功能 | 文件 | 行号 |
|------|------|------|
| `AllowedIPs` 类定义 | [allowedips.h](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.h) | 35-85 |
| `addPeer` 方法 | [allowedips.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp) | 84-102 |
| `applyMask` 方法 | [allowedips.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp) | 51-66 |
| `insertTrieNode` 方法 | [allowedips.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp) | 162-222 |
| `findPeer` 方法 | [allowedips.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp) | 104-142 |
| `findPeerForNodeTree` 方法 | [allowedips.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/allowedips.cpp) | 224-274 |
| `TrieNode` 结构 | [peer.h](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/peer.h) | 345-410 |
| `commonBits` 函数 | [tools.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/tools.cpp) | 214-234 |
| `prefixMatches` 函数 | [tools.cpp](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/tools.cpp) | 243-250 |
| `IPAddress` 结构 | [entity.h](file:///C:/Users/Leojay/workspace-wireguard/wireguard-CLJF/src/wg/entity.h) | 184-201 |
