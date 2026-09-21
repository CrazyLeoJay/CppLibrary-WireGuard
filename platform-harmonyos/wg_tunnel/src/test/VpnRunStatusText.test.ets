/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { describe, it, expect } from '@ohos/hypium';
import { VpnRunStatusState } from '../main/ets/keepalive/VpnKeepAliveManager';

/**
 * VpnRunStatusState.buildStatusText（主页运行状态条文案）单元测试
 *
 * 被测对象为真实源文件 ../main/ets/keepalive/VpnKeepAliveManager.ets 中的
 * VpnRunStatusState.buildStatusText 纯逻辑方法（@ohos.hilog 依赖经
 * src/mock/mock-config.json5 在测试构建期替换为空实现；AppStorageV2 装饰器
 * 在 LocalUnit 引擎下退化为普通字段，不影响纯文案逻辑）。
 *
 * 【用例组织】每个 it 验证一条文案行为：构造状态 + 断言完整文案。
 * 覆盖：Socket异常提示（含保鲜窗口/成功恢复清提示）、连接中两阶段、
 * 已连接心跳秒/分/小时换算、配置名拼装与缺名兜底。
 */

const BASE = 1_700_000_000_000;

function makeState(): VpnRunStatusState {
  const s = new VpnRunStatusState();
  s.running = false;
  s.runningConfigId = -1;
  s.handshakeOk = false;
  s.lastHeartbeatTime = 0;
  s.lastOutboundTime = 0;
  s.socketError = '';
  s.socketErrorTime = 0;
  return s;
}

export default function vpnRunStatusTextTest() {
  describe('vpnRunStatusText', () => {
    it('连接中_完全静默', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = false;
      s.lastOutboundTime = 0;
      const text = s.buildStatusText(BASE, '内网Ipv6');
      expect(text).assertEqual('内网Ipv6 · 连接中…');
    });

    it('连接中_已出站等待握手', 0, () => {
      const s = makeState();
      s.running = true;
      s.lastOutboundTime = BASE - 3000;
      const text = s.buildStatusText(BASE, '域名Ipv4');
      expect(text).assertEqual('域名Ipv4 · 连接中（已出站，等待握手响应）…');
    });

    it('已连接_心跳按秒展示', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 12_000;
      const text = s.buildStatusText(BASE, '域名Ipv4');
      expect(text).assertEqual('域名Ipv4 · 已连接 · 心跳12秒前');
    });

    it('已连接_心跳超过1分钟按分钟展示', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 5 * 60 * 1000;
      const text = s.buildStatusText(BASE, '');
      expect(text).assertEqual('已连接 · 心跳5分钟前');
    });

    it('已连接_心跳超过1小时按小时展示', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 2 * 3600 * 1000;
      const text = s.buildStatusText(BASE, '配置X');
      expect(text).assertEqual('配置X · 已连接 · 心跳2小时前');
    });

    it('Socket异常_保鲜窗口内优先提示', 0, () => {
      const s = makeState();
      s.running = true;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 5 * 1000;
      const text = s.buildStatusText(BASE, '内网Ipv4');
      expect(text).assertEqual('内网Ipv4 · Socket异常：连续发送失败');
    });

    it('Socket异常_超保鲜窗口回落心跳文案', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 10 * 1000;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 60 * 1000;
      const text = s.buildStatusText(BASE, '内网Ipv4');
      expect(text).assertEqual('内网Ipv4 · 已连接 · 心跳10秒前');
    });

    it('Socket异常_异常后有成功入站即视为恢复', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.socketError = '发送失败';
      s.socketErrorTime = BASE - 10 * 1000;
      s.lastHeartbeatTime = BASE - 2 * 1000;
      const text = s.buildStatusText(BASE, '域名Ipv4');
      expect(text).assertEqual('域名Ipv4 · 已连接 · 心跳2秒前');
    });

    it('已连接_无入站流量的明确提示', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = 0;
      const text = s.buildStatusText(BASE, '');
      expect(text).assertEqual('已连接（尚无入站流量）');
    });
  });
}
