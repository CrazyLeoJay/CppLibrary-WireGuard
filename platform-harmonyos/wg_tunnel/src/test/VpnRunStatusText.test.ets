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
import { VpnRunStatusState, VpnRunPhase } from '../main/ets/keepalive/VpnKeepAliveManager';

/**
 * VpnRunStatusState.buildStatusText / isBannerVisible（主页运行状态条）单元测试
 *
 * 被测对象为真实源文件 ../main/ets/keepalive/VpnKeepAliveManager.ets 中的
 * VpnRunStatusState 纯逻辑方法（@ohos.hilog 依赖经 src/mock/mock-config.json5
 * 在测试构建期替换为空实现；AppStorageV2 装饰器在 LocalUnit 引擎下退化为
 * 普通字段，不影响纯文案逻辑）。
 *
 * 【用例组织】每个 it 验证一条行为：构造状态 + 断言完整文案/可见性。
 * 覆盖：开关意图阶段文案（启动VPN中/关闭中/关闭成功，含对上一会话残留的优先级）、
 * 运行阶段逐级文案（服务已启动等待握手/已发起握手/握手成功过渡与回落）、
 * 已连接收/发双方向秒/分/小时换算、无收包/无发包的"无"占位（仅零值）、
 * Socket异常提示（保鲜窗口/成功恢复清提示/被意图阶段抢占）、
 * isBannerVisible 各阶段可见性与超时兜底、formatGap 边界。
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
  s.phase = VpnRunPhase.IDLE;
  s.phaseAt = 0;
  return s;
}

export default function vpnRunStatusTextTest() {
  describe('vpnRunStatusText', () => {
    // ===== 意图阶段：用户点击开/关后的链路文案（阶段优先，不回显上一会话残留） =====

    it('启动中_阶段文案', 0, () => {
      const s = makeState();
      s.phase = VpnRunPhase.STARTING;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('启动VPN中…');
    });

    it('启动中_阶段优先于上一会话残留', 0, () => {
      const s = makeState();
      s.phase = VpnRunPhase.STARTING;
      s.lastOutboundTime = BASE - 3000;   // 上一会话残留的出站时刻
      s.socketError = '连续发送失败';      // 上一会话残留的异常
      s.socketErrorTime = BASE - 2000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('启动VPN中…');
    });

    it('服务已启动_等待握手', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.SERVICE_UP;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('服务已启动，等待握手…');
    });

    it('已发起握手_等待响应', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.HANDSHAKING;
      s.lastOutboundTime = BASE - 2000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已发起握手，等待响应…');
    });

    it('握手成功_3秒内过渡文案', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.phaseAt = BASE - 1000;
      s.lastHeartbeatTime = BASE - 1000;
      s.lastOutboundTime = BASE - 2000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('握手成功，已连接');
    });

    it('握手成功_超3秒回落收发稳态文案', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.phaseAt = BASE - 5 * 1000;
      s.lastHeartbeatTime = BASE - 4000;
      s.lastOutboundTime = BASE - 2000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收4秒前 发2秒前');
    });

    it('连接确认_数据隐含确认无过渡文案', 0, () => {
      // 成功入站数据隐含连接确认（冷启动恢复场景）：phaseAt=0直接进稳态文案
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.phaseAt = 0;
      s.lastHeartbeatTime = BASE - 1000;
      s.lastOutboundTime = BASE - 2000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收1秒前 发2秒前');
    });

    it('关闭中_阶段文案', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.STOPPING;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('关闭中…');
    });

    it('关闭中_阶段优先于Socket异常', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.STOPPING;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('关闭中…');
    });

    it('关闭成功_阶段文案', 0, () => {
      const s = makeState();
      s.running = false;
      s.handshakeOk = false;
      s.phase = VpnRunPhase.STOPPED;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('关闭成功');
    });

    it('关闭成功_窗口内重启立即切新状态', 0, () => {
      // 展示期内重新开启：markStarting覆盖phase/phaseAt，消失窗口作废，直接展示新状态
      const s = makeState();
      s.phase = VpnRunPhase.STOPPED;
      s.phaseAt = BASE - 1000;   // 关闭成功展示中（窗口内）
      s.markStarting();
      expect(s.isBannerVisible(BASE)).assertTrue();
      expect(s.buildStatusText(BASE)).assertEqual('启动VPN中…');
    });

    // ===== 会话结束广播的阶段收敛（onSessionEnd） =====

    it('会话结束_关闭中转关闭成功', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.STOPPING;
      s.onSessionEnd(false);
      expect(s.phase).assertEqual(VpnRunPhase.STOPPED);
      expect(s.running).assertFalse();
    });

    it('会话结束_关闭成功不被迟到广播覆盖', 0, () => {
      // 主进程关VEA进程后onDestroy的STOP_VPN晚到几百毫秒：不得把"关闭成功"秒藏回IDLE
      const s = makeState();
      s.phase = VpnRunPhase.STOPPED;
      s.phaseAt = BASE - 500;
      s.onSessionEnd(false);
      expect(s.phase).assertEqual(VpnRunPhase.STOPPED);
      expect(s.phaseAt).assertEqual(BASE - 500);   // 计时不刷新，自然满保鲜期消失
    });

    it('会话结束_异常结束回IDLE', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.onSessionEnd(false);
      expect(s.phase).assertEqual(VpnRunPhase.IDLE);
      expect(s.running).assertFalse();
    });

    it('会话结束_强重启中间态保持运行展示', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.onSessionEnd(true);
      expect(s.phase).assertEqual(VpnRunPhase.SERVICE_UP);
      expect(s.running).assertTrue();
    });

    it('空闲_非运行返回空文案', 0, () => {
      const s = makeState();
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('');
    });

    // ===== 已连接稳态：收/发双方向时间换算 =====

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
      s.running = true;
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 5 * 60 * 1000;
      s.lastOutboundTime = BASE - 30 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收5分钟前 发30秒前');
    });

    it('已连接_收超过1小时按小时展示', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.lastHeartbeatTime = BASE - 2 * 3600 * 1000;
      s.lastOutboundTime = BASE - 5 * 60 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收2小时前 发5分钟前');
    });

    it('已连接_尚无收包但已有发包', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.lastHeartbeatTime = 0;
      s.lastOutboundTime = BASE - 5_000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收无 发5秒前');
    });

    // ===== Socket异常：运行阶段内保鲜窗口提示 =====

    it('Socket异常_保鲜窗口内优先提示', 0, () => {
      const s = makeState();
      s.running = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 5 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('Socket异常：连续发送失败');
    });

    it('Socket异常_超保鲜窗口回落收发文案', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.lastHeartbeatTime = BASE - 10 * 1000;
      s.lastOutboundTime = BASE - 4 * 1000;
      s.socketError = '连续发送失败';
      s.socketErrorTime = BASE - 60 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收10秒前 发4秒前');
    });

    it('Socket异常_异常后有成功入站即视为恢复', 0, () => {
      const s = makeState();
      s.running = true;
      s.handshakeOk = true;
      s.phase = VpnRunPhase.CONNECTED;
      s.socketError = '发送失败';
      s.socketErrorTime = BASE - 10 * 1000;
      s.lastHeartbeatTime = BASE - 2 * 1000;
      s.lastOutboundTime = BASE - 8 * 1000;
      const text = s.buildStatusText(BASE);
      expect(text).assertEqual('已连接 · 收2秒前 发8秒前');
    });

    // ===== isBannerVisible：阶段可见性与超时兜底 =====

    it('可见性_空闲隐藏', 0, () => {
      const s = makeState();
      expect(s.isBannerVisible(BASE)).assertFalse();
    });

    it('可见性_启动中在超时内可见', 0, () => {
      const s = makeState();
      s.phase = VpnRunPhase.STARTING;
      s.phaseAt = BASE;
      expect(s.isBannerVisible(BASE + 59 * 1000)).assertTrue();
      expect(s.isBannerVisible(BASE + 60 * 1000)).assertFalse();
    });

    it('可见性_运行各阶段恒可见', 0, () => {
      const s = makeState();
      s.running = true;
      s.phaseAt = BASE;
      s.phase = VpnRunPhase.SERVICE_UP;
      expect(s.isBannerVisible(BASE + 10 * 60 * 1000)).assertTrue();
      s.phase = VpnRunPhase.HANDSHAKING;
      expect(s.isBannerVisible(BASE + 10 * 60 * 1000)).assertTrue();
      s.phase = VpnRunPhase.CONNECTED;
      expect(s.isBannerVisible(BASE + 10 * 60 * 1000)).assertTrue();
    });

    it('可见性_关闭中超时兜底隐藏', 0, () => {
      const s = makeState();
      s.phase = VpnRunPhase.STOPPING;
      s.phaseAt = BASE;
      expect(s.isBannerVisible(BASE + 29 * 1000)).assertTrue();
      expect(s.isBannerVisible(BASE + 30 * 1000)).assertFalse();
    });

    it('可见性_关闭成功仅短暂展示', 0, () => {
      const s = makeState();
      s.phase = VpnRunPhase.STOPPED;
      s.phaseAt = BASE;
      expect(s.isBannerVisible(BASE + 2999)).assertTrue();
      expect(s.isBannerVisible(BASE + 3000)).assertFalse();
    });

    // ===== formatGap：时刻转"X前"可读间隔 =====

    it('formatGap_未来时刻视为刚刚', 0, () => {
      const s = makeState();
      // UI的nowTick每秒刷新，刚写入的时刻会领先它最多1秒：应显示刚刚而非无
      expect(s.formatGapBefore(BASE, BASE + 1000)).assertEqual('刚刚');
    });

    it('formatGap_零值返回无', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, 0)).assertEqual('无');
    });

    it('formatGap_不足1秒显示刚刚', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, BASE - 500)).assertEqual('刚刚');
      expect(s.formatGapBefore(BASE, BASE)).assertEqual('刚刚');
    });

    it('formatGap_分钟小时换算', 0, () => {
      const s = makeState();
      expect(s.formatGapBefore(BASE, BASE - 90 * 1000)).assertEqual('1分钟前');
      expect(s.formatGapBefore(BASE, BASE - 7300 * 1000)).assertEqual('2小时前');
    });
  });
}
