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
import VPNEventStatusParams, { VpnEventTag } from './entity/VPNEventStatusParams';
import { VpnConfigRequestParams } from './entity/VpnConfigAction';
import WGTools from './WGTools';
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
const VPN_CONFIG_QUERY = `${packageName}.VPN_CONFIG_QUERY` // VEA请求配置（V2模式）
const VPN_CONFIG_REQUEST = `${packageName}.VPN_CONFIG_REQUEST` // 主进程下发配置指令（V2模式）

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
      LLog.info(TAG, `Succeeded in creating subscriber. tag: ${this.tag}`);

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

  /**
   * 【跨进程广播】发布VPN状态变化事件
   *
   * 将VPN运行状态通过 CommonEventManager 广播给所有进程。
   * 广播数据中包含完整的 StatusConfig，确保主应用进程和VPN进程的状态一致。
   *
   * 【调用场景】
   * 1. VPN进程中：VPN启动成功(startVpn)、VPN停止(stopVpn)、VPN异常(startVpnThrow)
   * 2. 主应用进程中：用户主动关闭VPN(runWGConfig isOne=false)
   * 3. VPN进程中：响应主应用的状态查询(queryStatus)
   *
   * 【序列化注意事项】
   * StatusConfig 使用 @ObservedV2 + @Trace 修饰，AppStorageV2.connect 返回的是代理对象，
   * JSON.stringify 代理对象时 @Trace 属性名会被加 __ob_ 前缀导致反序列化失败，
   * 因此需要通过 toDTO() 转换为无装饰器的纯数据对象（StatusConfigDTO）再序列化。
   *
   * @param params VPN状态参数，其中 status 会自动填充
   */
  publishVpnChange(params: VPNEventStatusParams) {
    // 自动将当前进程的 StatusConfig 附加到广播数据中
    // VPN进程调用时：附带VPN进程的权威状态（running=true/false, runningConfigId）
    // 主应用进程调用时：附带主应用进程的本地状态
    // 通过 toDTO() 转换为纯数据对象，避免 @Trace 代理导致序列化属性名加 __ob_ 前缀
    params.status = WireGuard.config.status.getConfig().toDTO()
    this.publish(VPN_STATUS_CHANGE, JSON.stringify(params))
    LLog.info(TAG, `通知变化：${JSON.stringify(params)}`)
  }

  /**
   * 【跨进程订阅】订阅VPN状态变化事件
   *
   * 主应用进程和VPN进程都会订阅此事件，收到广播后：
   * 1. 解析广播数据中的 StatusConfig
   * 2. 调用 syncFromVpnProcess() 将VPN进程的权威状态同步到本地 AppStorageV2
   *    （无论广播是从VPN进程还是主应用进程发出的，都执行同步以确保一致性）
   * 3. 回调 paramsInvoke 通知UI层更新界面
   *
   * 【关键设计】
   * syncFromVpnProcess() 保证了"以VPN进程数据为准"的原则：
   *   - VPN启动/停止时，VPN进程广播的状态是权威的
   *
   * @param paramsInvoke 状态变化回调，返回解析后的 VPNEventStatusParams
   * @returns SubEventCancel 取消订阅的句柄
   */
  subscribeVpnChange(paramsInvoke: (result: VPNEventStatusParams) => void): SubEventCancel {
    return this.subscribe(VPN_STATUS_CHANGE, (data) => {
      if (data.data) {
        const result = JSON.parse(data.data) as VPNEventStatusParams
        // 【核心同步逻辑】收到VPN状态变化广播后，将状态同步到本地AppStorageV2
        // 以VPN进程数据为准，确保主应用进程的状态与VPN进程一致
        if (result.status) {
          WireGuard.config.status.syncFromVpnProcess(result.status)
        }
        paramsInvoke(result)
      }
    })
  }

  /**
   * 从主应用进程查询当前vpn状态
   * 如果VPN Extension正在运行，发送查询广播，VPN进程收到后会通过publishVpnChange回复最新状态
   * 主进程已通过subscribeVpnChange订阅，会自动同步
   * 如果VPN Extension未运行，直接广播isOpen=false
   */
  publishVpnStatusQuery() {
    WGTools.isVpnExtensionRunning()
      .then((running) => {
        if (running) {
          this.publish(VPN_STATUS_QUERY)
        } else {
          this.publishVpnChange({ isOpen: false, tag: VpnEventTag.QUERY_NO_RUNNING })
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

  /**
   * 【V2模式】VEA发布配置请求
   *
   * VEA进程启动后通过此方法请求主应用进程下发VPN配置。
   * 主应用进程收到后通过 publishVpnConfigRequest 回复配置。
   * VEA会以3秒间隔轮询，最多30次。
   */
  publishVpnConfigQuery() {
    this.publish(VPN_CONFIG_QUERY)
  }

  /**
   * 【V2模式】主应用进程订阅VEA配置请求
   *
   * 收到请求后，主应用进程应查询当前需要启动的配置并调用
   * publishVpnConfigRequest 下发配置指令。
   *
   * @param invoke 配置请求回调
   * @returns SubEventCancel 取消订阅的句柄
   */
  subscribeVpnConfigQuery(invoke: () => void): SubEventCancel {
    return this.subscribe(VPN_CONFIG_QUERY, () => {
      invoke()
    })
  }

  /**
   * 【V2模式】主应用进程下发配置指令
   *
   * 携带 VpnConfigRequestParams（action/configId/wgDbConf），
   * VEA进程收到后根据action执行对应操作（start/stop/switch/restart）。
   *
   * @param params 配置请求参数
   */
  publishVpnConfigRequest(params: VpnConfigRequestParams) {
    this.publish(VPN_CONFIG_REQUEST, JSON.stringify(params))
    LLog.info(TAG, `下发配置指令: action=${params.action}, configId=${params.configId}`)
  }

  /**
   * 【V2模式】VEA订阅配置指令
   *
   * VEA进程订阅此事件，收到主应用进程下发的配置指令后执行对应操作。
   *
   * @param invoke 配置指令回调，返回解析后的 VpnConfigRequestParams
   * @returns SubEventCancel 取消订阅的句柄
   */
  subscribeVpnConfigRequest(invoke: (params: VpnConfigRequestParams) => void): SubEventCancel {
    return this.subscribe(VPN_CONFIG_REQUEST, (data) => {
      if (data.data) {
        const params = JSON.parse(data.data) as VpnConfigRequestParams
        invoke(params)
      }
    })
  }

  publishVpnNoOpen(){
    WireGuard.event.publishVpnChange({ isOpen: false, tag: VpnEventTag.NO_START_VPN });
  }
}

const WGEvent = new WGSystemEventDef();

export default WGEvent;
