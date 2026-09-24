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
import VPNEventStatusParams, { VpnEventTag, shouldSyncEventStatus } from '../main/ets/model/entity/VPNEventStatusParams';
import { isFreshQueryReply } from '../main/ets/keepalive/VpnKeepAliveManager';
import { StatusConfigDTO } from '../main/ets/model/WGConfig';

/**
 * VPN事件新鲜度与同步判定单元测试
 *
 * 背景（2026-09-23事故）：主进程休眠唤醒后CommonEvent积压集中投递，
 * 陈旧startVpn广播抢先充当状态查询回复伪造"VEA存活"证据，导致消歧误判漏修复。
 *
 * 被测纯逻辑：
 * - shouldSyncEventStatus：QUERY_NO_RUNNING为none事件永不同步；ts单调门防陈旧倒灌；
 * - isFreshQueryReply：消歧回复仅接受查询类tag且发布时刻在新鲜窗口内。
 */

const BASE = 1_700_000_000_000;

function makeParams(tag: VpnEventTag, ts?: number): VPNEventStatusParams {
  const p: VPNEventStatusParams = { isOpen: true, tag: tag as string };
  if (ts != undefined) {
    p.ts = ts;
  }
  return p;
}

function withStatus(p: VPNEventStatusParams): VPNEventStatusParams {
  const dto = new StatusConfigDTO();
  dto.runningConfigId = 11;
  dto.running = true;
  p.status = dto;
  return p;
}

export default function vpnEventFreshnessTest() {
  describe('vpnEventFreshness', () => {
    // ===== shouldSyncEventStatus：none语义 + 单调同步门 =====

    it('同步_携带status的正常事件接受', 0, () => {
      const p = withStatus(makeParams(VpnEventTag.START_VPN, BASE));
      expect(shouldSyncEventStatus(p, BASE - 1000)).assertTrue();
    });

    it('同步_首次事件水位线为0接受', 0, () => {
      const p = withStatus(makeParams(VpnEventTag.START_VPN, BASE));
      expect(shouldSyncEventStatus(p, 0)).assertTrue();
    });

    it('none_QUERY_NO_RUNNING永不同步', 0, () => {
      // 自答回声/信息事件：即使携带status且ts最新，也不得倒灌本地状态
      const p = withStatus(makeParams(VpnEventTag.QUERY_NO_RUNNING, BASE));
      expect(shouldSyncEventStatus(p, BASE - 1000)).assertFalse();
    });

    it('同步_无status拒绝', 0, () => {
      const p = makeParams(VpnEventTag.START_VPN, BASE);
      expect(shouldSyncEventStatus(p, 0)).assertFalse();
    });

    it('单调门_ts落后水位线的积压广播拒绝', 0, () => {
      const p = withStatus(makeParams(VpnEventTag.START_VPN, BASE - 5000));
      expect(shouldSyncEventStatus(p, BASE - 1000)).assertFalse();
    });

    it('单调门_ts等于水位线接受', 0, () => {
      const p = withStatus(makeParams(VpnEventTag.START_VPN, BASE));
      expect(shouldSyncEventStatus(p, BASE)).assertTrue();
    });

    it('单调门_无ts视为0仅首播前接受', 0, () => {
      const p = withStatus(makeParams(VpnEventTag.START_VPN));
      expect(shouldSyncEventStatus(p, 0)).assertTrue();
      expect(shouldSyncEventStatus(p, BASE)).assertFalse();
    });

    // ===== isFreshQueryReply：消歧回复仅认查询类tag + 新鲜窗口 =====

    it('回复_新鲜queryStatus接受', 0, () => {
      const p = makeParams(VpnEventTag.QUERY_STATUS, BASE - 1000);
      expect(isFreshQueryReply(p, BASE, 5000)).assertTrue();
    });

    it('回复_新鲜queryNoRunning接受', 0, () => {
      const p = makeParams(VpnEventTag.QUERY_NO_RUNNING, BASE - 1000);
      expect(isFreshQueryReply(p, BASE, 5000)).assertTrue();
    });

    it('回复_非查询类startVpn拒绝', 0, () => {
      // 事故根因：陈旧startVpn(vpnThreadRunning=true)曾抢先充当回复伪造存活证据
      const p = makeParams(VpnEventTag.START_VPN, BASE - 1000);
      expect(isFreshQueryReply(p, BASE, 5000)).assertFalse();
    });

    it('回复_过期广播拒绝', 0, () => {
      const p = makeParams(VpnEventTag.QUERY_STATUS, BASE - 6000);
      expect(isFreshQueryReply(p, BASE, 5000)).assertFalse();
    });

    it('回复_等于新鲜窗口边界接受', 0, () => {
      const p = makeParams(VpnEventTag.QUERY_STATUS, BASE - 5000);
      expect(isFreshQueryReply(p, BASE, 5000)).assertTrue();
    });

    it('回复_无ts拒绝', 0, () => {
      const p = makeParams(VpnEventTag.QUERY_STATUS);
      expect(isFreshQueryReply(p, BASE, 5000)).assertFalse();
    });
  });
}
