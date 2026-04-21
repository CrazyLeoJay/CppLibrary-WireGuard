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
import WGAppException from '../error/WGAppException';
import { Endpoint, IPAddress, WGDeviceConfig } from './entity/WGClientConfig';

/**
 * WireGuard 配置获取助手
 * 可以通过以下方式获取配置
 * - 直接读取配置文件
 * - 通过二维码读取配置
 *
 * Created on 2026/4/17.
 * @author leojay`fu
 */
class WireGuardConfigHelper {
  /**
   * 读取到 配置内容 ini 格式
   *
   * 解析方式，一行一行读取，当碰到关键词，就采集对应的参数，判断参数是否为格式内需求参数。如果不是就抛出异常
   *
   * @param content
   * @returns
   */
  readConfig(content: string): WGDeviceConfig {
    const lines = content.split("\n")


    for (let line of lines) {

    }


    return {
      device: {
        deviceName: "",
        privateKey: "",
        publicKey: "",
      },
      peers: [],
    };
  }
}

interface WGInterface {
  privateKey?: string,
  listenPort?: number,
  Address?: IPAddress,
}

interface WGPeer {
  publicKey?: string,
  allowedIPs?: string,
  endpoint?: Endpoint,
  presharedKey?: string,
  keepaliveInterval?: string,
  maxBundleSize?: string,
}

/**
 * 用于判断读取到了哪个数据集
 */
enum WGReadMode {
  NONE, INTERFACE, PEER,
}

class ConfigReadBuilder {
  wgInterface: WGInterface = {};
  peers: WGPeer[] = [];
  peerIndex = -1;
  private mode: WGReadMode = WGReadMode.NONE;

  /**
   * 读取一行数据
   *
   * @param line
   */
  readLine(index: number, line: string) {
    switch (line) {
      case "[Interface]":
        this.mode = WGReadMode.INTERFACE;
        break
      case "[Peer]":
        this.mode = WGReadMode.PEER;
        this.peerIndex = this.peerIndex + 1;
        break
      default:
      // 数据读取
        this.analysisConfigLine(index, line)
        break
    }
  }

  /**
   * 解析配置行数据
   */
  private analysisConfigLine(index: number, line: string) {
    if (this.mode == WGReadMode.NONE) {
      throw new WGAppException(`未知配置(${index + 1} 行):${line}`);
    }
    switch (this.mode) {
      case WGReadMode.INTERFACE:
        this.readToInterface(index, line);
        break
      case WGReadMode.PEER:
        this.readToPeer(index, line);
        break
    }
  }

  /**
   * 读取数据到interface中
   * @param index
   * @param line
   */
  private readToInterface(index: number, line: string) {
    if (!line.includes("=")) {
      throw new WGAppException(`不是key=value格式(${index}行):${line}`)
    }
    const splitIndex = line.indexOf("=")
    if (splitIndex == line.length) {
      throw new WGAppException(`没有value(${index}行):${line}`)
    }
    const key = line.substring(0, splitIndex).trim()
    const value = line.substring(splitIndex + 1).trim()
    switch (key) {
      case "PrivateKey":
        this.check48Key(index, key, value)
        this.wgInterface.privateKey = value;
        break
      case "ListenPort":
        try {
          const port = Number.parseInt(value);
          if (port <= 0 || port > 65535) {
            throw new WGAppException(`(line:${index})ListenPort 不是合理的端口范围`)
          }
          this.wgInterface.listenPort = port;
        } catch (e) {
          throw new WGAppException(`(line:${index})ListenPort 必须是整数`)
        }
        break
    }
  }

  private readToPeer(index: number, line: string) {
    if (this.peerIndex < 0) {
      throw new WGAppException(`peerIndex 配置异常：${this.peerIndex}`)
    }
    let peer = this.peers[this.peerIndex]
    if (!peer) {
      peer = {}
      this.peers[this.peerIndex] = peer;
    }
    const splitIndex = line.indexOf("=")
    if (splitIndex == line.length) {
      throw new WGAppException(`没有value(${index}行):${line}`)
    }
    const key = line.substring(0, splitIndex).trim()
    const value = line.substring(splitIndex + 1).trim()
    switch (key) {
      case "PublicKey":
        this.check48Key(index, key, value)
        break
      case "Endpoint": // 指定远端点

        break
      case "AllowedIPs":
        break
      case "PresharedKey": // 可以为空
        if (!value) {
          break
        }
        if (value.length == 0) {
          break
        }
        this.check48Key(index, key, value)
        break
      case "KeepaliveInterval":
        break
      case "MaxBundleSize":
        break
    }
  }

  /**
   * 判断value是否为48位的key值
   */
  private check48Key(index: number, key: string, value: string) {
    if (value.length != 48) {
      throw new WGAppException(`(line:${index}) ${key} 的值不是正确的48位key`)
    }
  }
}