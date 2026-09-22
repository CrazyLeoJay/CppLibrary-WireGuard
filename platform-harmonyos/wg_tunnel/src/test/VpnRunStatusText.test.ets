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
 * VpnRunStatusState.buildStatusText / formatGapBefore 纯逻辑方法（@ohos.hilog
 * 依赖经 src/mock/mock-config.json5 在测试构建期替换为空实现；AppStorageV2
 * 装饰器在 LocalUnit 引擎下退化为普通字段，不影响纯文案逻辑）。
 *
 * 【用例组织】每个 it 验证一条文案行为：构造状态 + 断言完整文案。
 * 覆盖：Socket异常提示（含保鲜窗口/成功恢复清提示）、连接中两阶段、
 * 已连接收/发双方向秒/分/小时换算、无收包/无发包的"无"占位、未来时刻防御。
 * 文案不含配置名：主页开关行的选中态已表明当前配置。
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
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('连接中…');
    });

    it('连接中_已出站等待握手', 0, () => {
      const s = makeState();
      s.running = true;
      s.lastOutboundTime = BASE - 3000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('连接中（已出站，等待握手响应）…');
    });

    it('已连接_收发按秒展示', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 12_000;
      s.lastOutboundTime = BASE - 3_000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收12秒前 发3秒前');
    });

    it('已连接_收超过1分钟按分钟展示', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 5 * 60 * 1000;
      s.lastOutboundTime = BASE - 30 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收5分钟前 发30秒前');
    });

    it('已连接_收超过1小时按小时展示', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 2 * 3600 * 1000;
      s.lastOutboundTime = BASE - 5 * 60 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收2小时前 发5分钟前');
    });

    it('已连接_尚无收包但已有发包', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = 0;
      s.lastOutboundTime = BASE - 5_000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收无 发5秒前');
    });

    it('Socket异常_保鲜窗口内优先提示', 0, () => {
      const s = makeState();
      s.running = true;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 5 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('Socket异常：连续发送失败');
    });

    it('Socket异常_超保鲜窗口回落收发文案', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 10 * 1000;
      s.lastOutboundTime = BASE - 4 * 1000;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 60 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收10秒前 发4秒前');
    });

    it('Socket异常_异常后有成功入站即视为恢复', 0, () => {
      const s = makeState();
      s.handshakeOk = true;
      s.socketError = '发送失败';
      s.socketErrorTime = BASE - 10 * 1000;
      s.lastHeartbeatTime = BASE - 2 * 1000;
      s.lastOutboundTime = BASE - 8 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收2秒前 发8秒前');
    });

    it('formatGap_未来时刻防御返回无', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, BASE + 1000)).assertEqual('无');
    });

    it('formatGap_零值返回无', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, 0)).assertEqual('无');
    });

    it('formatGap_分钟小时换算', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, BASE - 90 * 1000)).assertEqual('1分钟前');
      expect(s.formatGapBefore(BASE, BASE - 7300 * 1000)).assertEqual('2小时前');
    });
  });
}
