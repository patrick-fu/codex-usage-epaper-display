# EPD-nRF5 与 UsageInk 独立 Swift BLE 实现互操作契约

研究日期：2026-08-18。目标是把 EPD-nRF5 的线协议表达成 UsageInk 可独立实现、可测试的契约；不复制 GPL 源码。上游仓库整体声明 GPL-3.0（见 [LICENSE](https://github.com/TSL0922/EPD-nRF5/blob/master/LICENSE)），因此本文只记录协议事实和独立算法描述。

## 结论先行

- 这是一个自定义 128-bit vendor GATT service：`62750001-d828-918d-fb46-b6c11c675aec`；主数据 characteristic `62750002-d828-918d-fb46-b6c11c675aec` 支持 read/write/write-without-response/notify；版本 characteristic `62750003-d828-918d-fb46-b6c11c675aec` 只读、单字节。
- 连接后必须先发现 service/characteristics、订阅主 characteristic 的 notify，再发 `INIT`。订阅成功会先收到固定长度 `epd_config_t` 配置通知；`INIT` 随后通知 `mtu=<N> rle=1` 与 `t=<unix-seconds>` 两条文本消息。
- 每个写入值的第一个字节是命令。`WRITE_IMAGE (0x30)` 的第二字节选择 black/red plane、是否该 plane 的首块、是否 RLE；后续字节是图像流。400×300 每 plane 是 `50×300 = 15,000` 字节，按行、每字节最高位对应最左像素。
- EPD-nRF5 没有应用层 ACK/序号/校验和。带 response 的 ATT 写入只确认 GATT 接收；without-response 可能静默丢失。因此 Swift 发送器应按 CoreBluetooth 可发送长度分片、限制无响应在途量，并在关键边界使用 response；无法证明整幅图像已被固件接收。
- `SET_PINS`、`SET_CONFIG` 会写入 FDS 持久化；wakeup pin 是高电平 sense，广播超时后可能进入系统睡眠，需外部唤醒。Mac 睡眠、BLE 断线、设备深睡都必须按“重连→重新发现→重新订阅→重新 INIT”恢复，不能假设 peripheral 仍可用。

## GATT、连接与发现

上游 [EPD_service.h](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/EPD_service.h) 定义 vendor base UUID 字节 `EC 5A 67 1C C1 B6 46 FB 8D 91 28 D8 22 36 75 62`，short UUID 为 service `0x0001`、data characteristic `0x0002`、version `0x0003`。Web UI 使用上述三个 canonical UUID（[main.js](https://github.com/TSL0922/EPD-nRF5/blob/master/html/js/main.js)）。设备把 service UUID 放在 advertising/scan response；名字是完整设备名，广告 flags 为 LE limited discoverable。

Swift 侧应等待 `CBCentralManagerState.poweredOn`，以 service UUID 扫描，保留 `CBPeripheral` 强引用，连接后只发现该 service 的三个 characteristic。Apple 的 [CBCentralManager 文档](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager)和 [扫描文档](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals%28withservices%3Aoptions%3A%29)确认了这些生命周期要求；连接后按 [CBPeripheral discoverServices](https://developer.apple.com/documentation/corebluetooth/cbperipheral/discoverservices%28_%3A%29) / `discoverCharacteristics` 顺序执行。

主 characteristic 的属性来自 `EPD_service.c`：read、write、write without response、notify，访问权限均 open，CCCD open。版本 read 失败或不存在时，Web UI 以 `0x15` 作为旧固件兼容回退；版本 `< 0x16` 可能不支持 `WRITE_IMAGE`/RLE，应拒绝新路径或切换保守路径。版本当前固件常量为 `0x1a`，但不能把该值当作所有硬件的能力证明。

## MTU、通知和 ACK 边界

固件以 `effective ATT MTU - 3` 作为 payload 上限（旧 nRF51 默认 `GATT_MTU_SIZE_DEFAULT - 3`；nRF52 S112 由 GATT 事件更新），并在 INIT 后通知 `mtu=N rle=1`。`N` 是**命令后的数据预算**：单次 characteristic value 总长度不得超过 `N + 3` ATT MTU；`WRITE_IMAGE` 因命令字和 flags 各占 1 字节，图像 chunk 最大为 `N - 2`。若没有收到该通知，保守按默认 ATT MTU 23，即 `N=20`、图像 chunk 18 字节。

Swift 不应硬编码 20 或把 Apple 的 `maximumWriteValueLength(for:)` 当作固件通知的替代；应取二者较小值，并在每个写入前检查 characteristic 属性。Apple 说明 [maximumWriteValueLength](https://developer.apple.com/documentation/corebluetooth/cbperipheral) 返回单次写入上限；[writeValue](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue%28_%3Afor%3Atype%3A%29) 明确指出 without-response 不保证成功，而 with-response 才有 `didWriteValueFor` 回调。`canSendWriteWithoutResponse` 变为 true 前不要继续灌入无响应队列。

通知是有序但无类型字段的字节流：首次订阅通知是 config，之后按连接会话接收文本 `mtu=...`、`t=...`。实现应先以长度/状态机识别 config，再 UTF-8 解码文本；不要把任意通知误判为 ACK。固件没有失败响应、写入序列号、分片计数或 CRC；超时只能判定“未观察到预期通知/连接事件”，不能证明设备没有执行。

## 命令状态机

所有命令格式为 `[opcode][arguments...]`，长度不足时固件静默返回。

| 阶段 | 写入 | 精确行为 |
|---|---|---|
| 订阅 | CCCD enable notify | 固件立即通知 `epd_config_t`（13 字节，当前 struct 顺序：mosi,sclk,cs,dc,rst,busy,bs,model,wakeup,led,en,display_mode,week_start）。|
| 初始化 | `01 [model_id?]` | `epd_init(model_id 或持久化 model)`；若探测 id 改变则持久化；通知 `mtu=N rle=1`，再通知 `t=...`。应作为每次连接恢复的幂等起点。|
| 图像写入 | `30 [flags] [data...]` | flags bit0：`0=black`、`1=red`；bit1：该 plane 首块；bit2：RLE。首块 black 会设置整屏窗口；首块 red 只切换 plane。|
| 刷新 | `05` | 调用显示驱动 refresh，并等待 busy；没有应用层完成通知。只有该命令后才把 Display Frame 视为提交。|
| 可选睡眠 | `06` | 让 EPD controller 睡眠，不等同 MCU 深睡；下一次写入前应重新 INIT。|
| 配置 | `90 [bytes...]` | 复制最多 13 字节到 config 并写 FDS；没有 schema/version/ACK。未知或短 payload 也可能覆盖部分字段，Swift 应只发送完整快照。|

其他恢复/维护命令：`00 [>=7 pin bytes]` 设置并持久化 pin（第 8 个可选 en pin）；`02 [bool?]` clear；`03 [controller command]`、`04 [raw data]` 直通 SPI；`91` MCU reset；`92` 进入系统 sleep；`99` 删除配置后 reset。UsageInk 默认不暴露直通/擦除/reset 命令。

## 400×300 BW/BWR 编码与 RLE

EPD-nRF5 的 400×300 模型在 [SSD16xx.c](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/SSD16xx.c) 中声明。每行宽度向上取整为 50 字节，像素按 row-major 排列，x=0 使用 bit7、x=7 使用 bit0；白为 1、黑为 0。BWR 需先完整发送 black plane，再完整发送 red plane；每 plane 15,000 字节。红 plane 中 bit=0 表示红，bit=1 表示非红；black plane 决定非红像素黑/白。

每个 plane 的首包 flags：black `0x02`，red `0x03`；后续分别 `0x00`、`0x01`；启用 RLE 时各自再 OR `0x04`。每个包的图像数据不能超过 `chunkSize = N-2`。首个 black 包让驱动设定整屏窗口；若只发 red 而未先发 black，窗口/控制器状态不应视为可靠。

RLE 是独立的 byte stream：控制字 bit7=1 表示重复，长度 `(control & 0x7f)+3`，随后 1 个 value byte；bit7=0 表示 literal，长度 `control+1`，随后这些 literal bytes。一个 RLE code 不得跨 BLE chunk；固件每包从 offset 0 解码，并以 `begin` 只作用于该 plane 的首包。上游 Web UI 仅当完整 RLE 流短于原始流时使用 RLE，并把流按 code 边界切片（[rle.js](https://github.com/TSL0922/EPD-nRF5/blob/master/html/js/rle.js)）。若 RLE 无收益，发送原始 bytes，flags bit2 清零。

测试 fixture 至少包含：全白（每 plane `FF`）、全黑（black `00`/red `FF`）、全红（black `FF`/red `00`）、左上 8 像素图案 `[80,40,20,10,08,04,02,01]`、跨 chunk 的 130-byte repeat、literal 128-byte code、以及 chunk 边界恰落在 code 前后。解码后必须逐字节等于 15,000-byte golden plane；再验证 flags 和发送顺序。

## 持久设置、睡眠与恢复边界

config 从 nRF FDS 读写；未找到记录时初始化为 `0xFF`。`wakeup_pin != 0xFF` 时，固件配置该 GPIO 为无上下拉、上升沿/高电平 sense。快速广告超时后：picture mode 进入 `sleep_mode_enter()`；calendar mode 则配置 wakeup pin 并等待外部高电平；无 wakeup pin 则继续广播。连接建立/断开还会初始化/睡眠 EPD GPIO。故 Mac 睡眠造成的断线、设备广告超时、外部唤醒均是正常状态迁移，不是可依赖的长连接。

恢复策略：取消旧 CoreBluetooth delegate 工作；重新扫描/或用已知 peripheral identifier retrieve 后连接；重新发现 service/chars、打开 notify、等待 config、重新 `INIT`；只有收到新的 `mtu=` 后才恢复传输。若刷新过程中断线，不能从未知 offset 续传：重新 INIT，重发 black+red 两个完整 plane，再发 REFRESH。配置写入无 ACK，必要时断开重连并等待 config 通知验证；wakeup pin、pin mapping、model id 的实际硬件效果仍需实机验证。

## 能力探测与未决实机验证

可靠探测顺序是：service UUID → 三个 characteristic 属性 → version read → notify config → `INIT` 后解析 `mtu=`/`rle=1`。仅有 service 不足以证明 400×300、BWR 或 RLE 能力；版本号也不是完整 capability bitmap。Swift 应将尺寸、颜色、driver model 作为用户/设备配置，并在发送前校验 plane 长度。

必须在真实 nRF51、nRF52810/11 和至少一块 UC8176/SSD1619 400×300 面板验证：ATT MTU 协商下最大有效 payload；write-without-response 的可持续窗口与丢包行为；Notify 首包 config 的确切长度/顺序；`INIT` 对 model id 的探测及不匹配行为；RLE 跨包解码；黑/红 plane 极性；refresh busy 时长；`SET_CONFIG`/wakeup pin 持久化；广告超时和外部唤醒；MCU sleep/reset 后重连；以及 macOS 睡眠/唤醒期间 CoreBluetooth 回调顺序。源码未定义 ACK、超时、重试或原子提交语义，以上均不能靠模拟器“推断”为已保证。

## 一手来源

- [EPD_service.h](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/EPD_service.h)、[EPD_service.c](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/EPD_service.c)：UUID、opcode、MTU、notify、命令处理、RLE、睡眠。
- [html/js/main.js](https://github.com/TSL0922/EPD-nRF5/blob/master/html/js/main.js)、[html/js/rle.js](https://github.com/TSL0922/EPD-nRF5/blob/master/html/js/rle.js)、[html/js/dithering.js](https://github.com/TSL0922/EPD-nRF5/blob/master/html/js/dithering.js)：实际 Web BLE 顺序、flags、plane 编码和分片实现。
- [EPD_config.h/.c](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/EPD_config.h)、[main.c](https://github.com/TSL0922/EPD-nRF5/blob/master/main.c)、[SSD16xx.c](https://github.com/TSL0922/EPD-nRF5/blob/master/EPD/SSD16xx.c)：配置布局、FDS 持久化、广播/唤醒和 400×300 plane 写入。
- Apple [Core Bluetooth central](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager)、[CBPeripheral](https://developer.apple.com/documentation/corebluetooth/cbperipheral)、[writeValue](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue%28_%3Afor%3Atype%3A%29)：Swift 连接、发现、通知、最大写入长度及 with/without-response 语义。
