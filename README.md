# Fan Butler — 风扇管家

超微（Supermicro）主板风扇管理工具。通过 Windows 自带的 IPMI 驱动读取传感器、切换风扇模式，不依赖 ipmitool、IPMICFG 或 BMC 账号。

在 Supermicro X12DAi-N6（双 Xeon 8383C，BMC 固件 1.3）上开发并验证：BMC 处于 Full 模式时四个在位风扇约 1500–2100 RPM，切换到 Optimal 后待机 420 RPM，CPU 温度 45 °C 左右。

## 使用

要求：Windows、管理员权限。设备管理器中存在 "Microsoft Generic IPMI Compliant Device" 即具备驱动条件，该驱动系统自带。

图形界面：运行 `fan-ui.ps1`。WPF 界面，显示转速、温度、当前模式，可切换三种模式。

命令行：

```powershell
.\fan.ps1 status          # 查看风扇/温度/电压/当前模式
.\fan.ps1 mode optimal    # 切到智能调速（日常推荐）
.\fan.ps1 mode standard   # 出厂默认
.\fan.ps1 mode full       # 全速
.\fan.ps1 set cpu 40      # 尝试手动转速；是否生效取决于 BMC 固件，见下文
```

`make-icon.ps1` 重新生成程序图标。

## 关于超微 BMC 风扇命令的实测结果

以下结论来自 X12DAi-N6 / BMC 1.3 的实机测试，换固件或换主板后未必适用。

1. 设置风扇模式的编码是 `raw 0x30 0x45 0x01 <模式>`。网上流传的 `0x00 <模式>` 写法，BMC 会返回成功但不执行。如果你在 BMC 网页里调速"无效、过段时间回弹"，可以往这个方向排查。`0x30 0x45 0x00` 是查询；模式值：0=Standard，1=Full，2=Optimal，3=Heavy IO。
2. 占空比写入（`raw 0x30 0x70 0x66 0x01 <区> <百分比>`）在这块固件上即使返回成功也未必执行，需要用读回命令 `raw 0x30 0x70 0x66 0x00 <区>` 验证。本机在 Standard、Optimal、Full 三种模式下都拒绝手动占空比，转速完全由 BMC 曲线决定，因此模式切换是唯一有效的调整手段。固件更新后此行为可能变化，`set` 命令保留，执行时会如实报告验证结果。
3. Windows IPMI 驱动（WMI `root\WMI\Microsoft_IPMI` 的 `RequestResponse` 方法）返回的 `ResponseData` 首字节是完成码回显，真实数据从第二字节开始。
4. 这台 BMC 的 SDR 传感器记录 ID 从 0x0004 起按 +0x43 步长排列，链表 next-id 的高字节不可靠，按步长扫描可行；换算字段位于记录的第 21（单位）、26–27（M）、28–29（B）、31（Rexp/Bexp）字节，与 IPMI 规范的偏移不同。以上均用电压传感器交叉验证过（12 V 轨计算值 11.83 V，与标称相符）。

## 安全设计

- 读写分离：`status` 只读；模式切换是 BMC 官方功能，随时可以改回。
- `set` 有 20% 转速下限和读回验证，被固件拒绝时不改变任何状态，只报告结果。
- 切换全速模式需要二次确认。
- 恢复路径：`.\fan.ps1 mode standard`，或在 BIOS 中恢复默认设置。

## 致谢

- [KCORES/fan-lord](https://github.com/kcores/fan-lord) 与 [cyberbus 的博客](https://cyberbus.net/post/129)：项目的起点和命令参考
- [FanControl](https://github.com/Rem0o/FanControl.Releases)：GUI 设计参考

## English TL;DR

Fan management for Supermicro boards over the native Windows IPMI driver (WMI). No ipmitool, IPMICFG, or BMC credentials required. CLI (`fan.ps1`) + WPF GUI (`fan-ui.ps1`).

Verified on X12DAi-N6 / BMC 1.3: fan-mode set must use `raw 0x30 0x45 0x01 <mode>` — the widely circulated `0x00 <mode>` encoding returns success but is silently ignored; duty writes must be verified via readback (`0x30 0x70 0x66 0x00 <zone>`) because this firmware accepts-but-ignores them in all modes; the Windows driver prefixes response data with a completion-code echo byte; SDR records sit at IDs `0x0004 + k*0x43` with calibration fields at non-standard offsets (unit at 21, M at 26–27, B at 28–29, exponents at 31).
