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
import { commonEventManager } from '@kit.BasicServicesKit';
import { LLog, StreamLogMessage, WireGuard } from '../../../../Index';
import { bundleManager } from '@kit.AbilityKit';
import VPNEventStatusParams from './entity/VPNEventStatusParams';
import WGTools from './WGTools';
import { StatusConfig } from './WGConfig';
import { WGEventThrow, WGEventThrowForString, WGEventThrowParam, WGEventThrowToString } from '../error/WGEventThrow';

/**
 * WireGuard 事件发布
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */
const TAG = "WireGuard公共事件"

let bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
const packageName = bundleInfo.name

const VPN_START_ERROR = `${packageName}.VPN_ERROR`
const VPN_START_CLOSE = `${packageName}.VPN_CLOSE`
const VPN_STATUS_CHANGE = `${packageName}.VPN_STATUS_CHANGE` // VPN状态变化
const VPN_STATUS_QUERY = `${packageName}.VPN_STATUS_QUERY` // VPN状态查询
const VPN_STREAM_LOGS = `${packageName}.VPN_STREAM_LOGS` // VPN Stream 流日志

export interface SubEventCancel {
  cancel(): void
}

export class SubEvent implements SubEventCancel {
  tag: string
  sub: commonEventManager.CommonEventSubscriber

  constructor(tag: string) {
    this.tag = tag;
    this.sub = commonEventManager.createSubscriberSync({
      events: [tag],
    })
  }

  subscribe(invoke: (data: commonEventManager.CommonEventData) => void, error?: (err: BusinessError) => void) {
    commonEventManager.subscribe(this.sub, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (err) {
        LLog.error(TAG, `Failed to create subscriber. Code is ${err.code}, message is ${err.message}`);
        error?.(err)
        return;
      }
      LLog.info(TAG, 'Succeeded in creating subscriber.');

      try {
        invoke(data)
      } catch (err) {
        LLog.error(TAG, err)
        error?.(err)
      }
    })
  }

  cancel() {
    commonEventManager.unsubscribe(this.sub, () => {
      LLog.info(TAG, `取消订阅: ${this.tag}`)
    })
  }
}

/**
 * 跨进程系统通知
 */
export class WGSystemEventDef {
  private publish(tag: string, data?: string) {
    try {
      const callback = (err: BusinessError, data: void) => {
        if (err) {
          const code = JSON.stringify(err.code)
          const msg = JSON.stringify(err.message);
          LLog.error(TAG, `发布 (${tag}) 事件 failed, code is ${code}, message is ${msg}`)
        } else {
          LLog.info(TAG, `发布 (${tag}) 事件 success。data=${data}`);
        }
      }
      if (data) {
        commonEventManager.publish(tag, { data: data }, callback)
      } else {
        commonEventManager.publish(tag, callback)
      }
    } catch (e) {
      LLog.error(TAG, {
        error: e,
        message: `发布(${tag})异常`
      })
    }
  }

  private subscribe(
    tag: string,
    invoke: (data: commonEventManager.CommonEventData) => void,
    error?: (err: BusinessError) => void
  ): SubEventCancel {
    const sub = new SubEvent(tag);
    sub.subscribe(invoke, error)
    LLog.info(TAG, `注册全局 ${tag} 事件监听`)
    return sub;
  }

  publishVpnThrow(msg?: WGEventThrowParam) {
    this.publish(VPN_START_ERROR, WGEventThrowToString(msg))
  }

  subscribeVpnThrow(invoke: (param: WGEventThrow) => void): SubEventCancel {
    return this.subscribe(VPN_START_ERROR, (data) => {
      if (data.data) {
        invoke(WGEventThrowForString(data.data))
      } else {
        invoke({ type: 'none', message: "为获取到异常数据，需要核查" })
      }
    })
  }

  publishVpnChange(params: VPNEventStatusParams) {
    params.status = WireGuard.statusConfig.getConfig()
    this.publish(VPN_STATUS_CHANGE, JSON.stringify(params))
  }

  subscribeVpnChange(paramsInvoke: (result: VPNEventStatusParams) => void): SubEventCancel {
    return this.subscribe(VPN_STATUS_CHANGE, (data) => {
      if (data.data) {
        const result = JSON.parse(data.data) as VPNEventStatusParams
        const vsp: VPNEventStatusParams = {
          isOpen: result.isOpen,
          tag: result.tag,
        }
        if (result.status) {
          const sc = new StatusConfig()
          sc.runningConfigId = result.status?.runningConfigId
          sc.running = result.status.running
          vsp.status = sc
        }
        paramsInvoke(vsp)
      }
    })
  }

  /**
   * 这个主要是从UI线程去查询当前vpn状态，需要在非UI线程调用
   */
  publishVpnStatusQuery() {
    WGTools.isVpnExtensionRunning()
      .then((running) => {
        if (running) {
          this.publish(VPN_STATUS_QUERY)
        } else {
          this.publishVpnChange({ isOpen: false, tag: "query for vpn no running" })
        }
      })
  }

  subscribeVpnStatusQuery(paramsInvoke: () => void): SubEventCancel {
    return this.subscribe(VPN_STATUS_QUERY, (data) => {
      paramsInvoke()
    })
  }

  publishVpnStreamLogs(msg: StreamLogMessage) {
    this.publish(VPN_STREAM_LOGS, JSON.stringify(msg))
  }

  subscribeVpnStreamLogs(logListener: (msg: StreamLogMessage) => void): SubEventCancel {
    return this.subscribe(VPN_STREAM_LOGS, (data) => {
      if (data.data) {
        const log = JSON.parse(data.data) as StreamLogMessage
        logListener(log);
      }
    })
  }
}

const WGEvent = new WGSystemEventDef();

export default WGEvent;
