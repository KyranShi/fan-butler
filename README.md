# Fan Butler — 风扇管家

超微 (Supermicro) 主板风扇管理工具 · Windows 原生 IPMI 通道 · **零依赖单文件**

[English TL;DR](#english-tldr)

## 它解决什么问题

超微服务器的 BMC 把风扇策略锁死时（比如固定 Full 全速），机器像直升机一样吵。
本工具通过 **Windows 系统自带的 IPMI 驱动**（WMI: `root\WMI\Microsoft_IPMI`）直接与 BMC 对话，
查看全部传感器并切换风扇工作模式 —— 不需要装 ipmitool、不需要 IPMICFG、不需要 BMC 账号密码。

在 Supermicro X12DAi-N6 + 双 Xeon 8383C 上实测：**Full 全速 1540 RPM 咆哮 → Optimal 模式待机 420 RPM，温度全部安全**。

## 使用

需要：Windows + 管理员权限 + 设备管理器里有 "Microsoft Generic IPMI Compliant Device"（Windows 自带）。

**图形界面（推荐）**：双击 `fan-ui.ps1`（或其快捷方式），WPF 浅色界面，实时转速/温度/模式，一键切换。

**命令行**：

```powershell
.\fan.ps1 status          # 查看风扇/温度/电压/当前模式
.\fan.ps1 mode optimal    # 切到智能调速 (日常推荐)
.\fan.ps1 mode standard   # 出厂默认
.\fan.ps1 mode full       # 全速 (吵)
.\fan.ps1 set cpu 40      # 尝试手动转速 (是否生效取决于 BMC 固件, 见下)
```

`make-icon.ps1` 重新生成程序图标（GDI+ 矢量绘制 → 多尺寸 ICO）。

## 独家发现 (逆向 X12DAi-N6 / BMC 1.3 实测, 或对你有用)

网络上流传的超微风扇命令有几个坑，全部用真实硬件验证过：

1. **设置风扇模式的正确编码是 `raw 0x30 0x45 0x01 <模式>`**。
   `0x00 <模式>` 是错误写法 —— BMC 会返回成功但**静默不执行**。
   这大概率就是"BMC 网页/命令调了没效果、过会儿回弹"的真正原因。
   （`0x30 0x45 0x00` 是查询；模式值：0=Standard 1=Full 2=Optimal 3=Heavy IO）
2. **占空比读回命令 `raw 0x30 0x70 0x66 0x00 <区>` 是验证调速是否生效的可靠手段**。
   写入 `0x30 0x70 0x66 0x01 <区> <百分比>` 即使返回 CC=0 也可能未执行——必须读回验证。
   本机固件在 Standard/Optimal/Full 下均拒绝手动占空比（读回始终是 BMC 曲线值），
   即固件较老时"模式切换"才是唯一有效杠杆；`set` 命令保留并在固件升级后可能直接可用。
3. **Windows IPMI 驱动的响应格式**：`RequestResponse` 的 `ResponseData` 首字节是完成码回显，
   真实 IPMI 负载从第 2 字节开始。
4. **SDR 传感器仓库的怪癖**（此固件）：GetSDR 返回 `[nextId(2B)][记录]`；记录 ID 从 0x0004 起
   等差 **+0x43** 排列（链表 next-id 高字节不可靠，按步长扫描最稳）；换算字段在记录的
   [21]=单位 [26..27]=M [28..29]=B [31]=Rexp/Bexp（与规范有偏移，已用电压传感器反推验证）。

诊断证据链在 `diag*.ps1`（12 个递进实验脚本），复现以上结论的原始数据均可回查。

## 安全设计

- 只读与模式切换分离；模式切换是 BMC 官方功能，随时可逆；
- `set` 带 20% 转速下限 + 读回验证，被固件拒绝时如实报告且不改变任何状态；
- 全速模式切换带二次确认；
- 极端情况的终极恢复：`.\fan.ps1 mode standard` 或 BIOS 里恢复默认。

## 致谢

- [KCORES/fan-lord](https://github.com/kcores/fan-lord) 与 [cyberbus 的博客](https://cyberbus.net/post/129) —— 本项目的起点与命令参考；
- [FanControl](https://github.com/Rem0o/FanControl.Releases) —— GUI 设计语言参考。

## English TL;DR

Fan management for Supermicro boards over the **native Windows IPMI driver** (zero dependencies, no ipmitool/IPMICFG/BMC credentials). CLI (`fan.ps1`) + WPF GUI (`fan-ui.ps1`).
Verified findings on X12DAi-N6 / BMC 1.3: fan-mode set must use `raw 0x30 0x45 0x01 <mode>` (the widely-circulated `0x00 <mode>` encoding is silently ignored); duty writes must be verified via readback (`0x30 0x70 0x66 0x00 <zone>`) since this firmware accepts-but-ignores them in all modes; the Windows IPMI driver prefixes response data with an extra completion-code echo byte; SDR records live at IDs `0x0004 + k*0x43` with calibration fields at non-standard offsets (see `diag*.ps1` for the evidence chain).
