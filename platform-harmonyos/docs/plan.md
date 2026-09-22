# 开发计划

- [x] 基本功能
  - [x] 构建`WireGuard`通道，与其他端可通讯
  - [x] 建立系统VPN
  - [x] 通过二维码扫描添加配置
  - [x] 通过文件添加配置
  - [x] 手动添加配置
  - [X] 基础的应用过滤
  - [x] 配置预览和启动
  - [x] 设置和关于
- [ ] 作者定制功能
  - [ ] 对端`ip`多样化获取方式。
  - [ ] 应用过滤配置（可以单独构建应用过滤规则，配置哪个生效。）



# 用户建议采集

- [ ] 桌面小组件：我是鸿蒙pc，固定在桌面上，直接一点就开启会比较方便
- [ ] 组网后没有成功组网信息，很多人估计不知道成功组网
  - [ ] 红*******2026-07-30 16:23:59*![img](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAZpJREFUOE+l08FLVFEYBfDzvacZLqWFi1YuFENaunFjO8GZ+yAwZKT7QMbmvvAfkFpEFkQQBUHzBhcxb1RaWDDvSkGbWYj7GNxkSCAquGllK8d7RKEJqpdpd3nvd36L83EF/3kkK1+p2G52u0VS1iKtnmfNZQOJLRCcAuQ7gKbR+Ud/QjKBuGpfANgWtuoU/4MJVf/5gCT9JHAlcd6B8/jO6GDgn4G4Vn9KynCk1eirpdU+/8hNl7S6nwk8aDQ6encOCnSuTyD9AAf9TozNFIL9ci29Bcdr7bDIIUl7NwyaJ3enHZSr6WMR3CD5UURmCW800rmNk7c4qd8kcf0HIJDLEBSFnCiFQeMUqCTpCilvTJhfiZP6Z/hezkzlv2StLk6sAdyQ0cHs70A13fTg5+6E45tZQLlmH8LRj0J170JAnNhVCl9Ht9XbiwJ7Pjgyo9XXc3ewsPj+6pFrNY1WPe0tVKr2JcV1UbxlIROKzAHY/bUDEfhwfAJgy2g1+RNYtlfYcvOEDJ75OYn1zsNLz4rFsW9t4MzQXwaOARJR0BEtmZiOAAAAAElFTkSuQmCC)*0
  - [ ] 1、导入含IPv6路由时，会将IPv6路由转换成[::]/0格式，导致开启VPN失败；
  - [ ]  2、导入配置文件时会重复生成两个同样的配置； 
  - [ ] 3、不能过滤应用，所有应用流量全走VPN，这样可科学呀，希望增加应用过滤功能，按需选择使用VPN的应用； 
  - [ ] 4、左划配置点击删除，红色删除按钮不消失，下面的配置会向上移动到删除位置并处于删除状态，可能造成误删；
- [ ] **AmneziaWG（简称AWG）是经典VPN协议WireGuard的一个特殊分支（Fork）**，它在保留WireGuard高速、简洁等核心优点的同时，通过先进的流量混淆技术，旨在对抗深度数据包检测（DPI）系统的识别和封锁