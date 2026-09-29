import Foundation

/// `--dump` 诊断命令：把三个采集器的解析结果打到标准输出，用于核对字段映射。
///
/// 排查「某个字段没显示出来」时，先跑这个，比在界面上猜快得多。
enum DumpCommand {

    static func run() {
        print("=== 0. 原始属性类型诊断 ===")
        if let raw = RegistrySampler.readRawProperties() {
            for key in ["LifetimeData", "BatteryData", "PowerTelemetryData", "ChargerData", "AdapterDetails"] {
                let value = raw[key]
                let typeName = value.map { String(describing: type(of: $0)) } ?? "nil"
                var extra = ""
                if let dict = value as? [String: Any] {
                    extra = " 可桥接为字典，键数 \(dict.count)"
                } else {
                    extra = " 无法桥接为 [String: Any]"
                }
                print("  \(key): \(typeName)\(extra)")
            }
            if let life = raw["LifetimeData"] as? [String: Any] {
                print("  LifetimeData.TotalOperatingTime = \(String(describing: life["TotalOperatingTime"]))  type=\(life["TotalOperatingTime"].map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
        print("")

        print("=== 1. RegistrySampler（AppleSmartBattery）===")
        if let s = RegistrySampler.sample() {
            dump(s)
        } else {
            print("  读取失败：本机可能没有 AppleSmartBattery 节点")
        }

        print("")
        print("=== 2. PowerSourceSampler（IOKit 公开 API）===")
        if let info = PowerSourceSampler.batteryInfo() {
            p("主要电量", info.currentCapacity)
            p("最大容量", info.maxCapacity)
            p("充电中", info.isCharging)
            p("即将充满", info.isFinishingCharge)
            p("存在", info.isPresent)
            p("距充满(分)", info.timeToFullMinutes)
            p("距放完(分)", info.timeToEmptyMinutes)
            p("电池健康", info.batteryHealth)
            p("健康条件", info.healthCondition)
            p("电源状态", info.powerSourceState)
            p("设计循环", info.designCycleCount)
            p("传输类型", info.transportType)
        } else {
            print("  未找到内置电池")
        }

        print("")
        print("=== 3. 适配器（IOPSCopyExternalPowerAdapterDetails）===")
        if let adapter = PowerSourceSampler.adapterInfo() {
            p("名称", adapter.name)
            p("厂商", adapter.manufacturer)
            p("额定(W)", adapter.watts)
            p("协商电压(mV)", adapter.negotiatedVoltageMV)
            p("协商电流(mA)", adapter.negotiatedCurrentMA)
            p("无线", adapter.isWireless)
            p("档位", adapter.pdoMenu.map { "\($0.voltageMV)mV/\($0.currentMA)mA" }.joined(separator: ", "))
        } else {
            print("  未连接适配器")
        }

        exit(0)
    }

    private static func dump(_ s: BatterySnapshot) {
        p("有电池", s.hasBattery)
        p("电量", s.percentage)
        p("充电中", s.isCharging)
        p("已充满", s.isFullyCharged)
        p("外接电源", s.isExternalConnected)
        p("距充满(分)", s.timeToFullMinutes)
        p("距放完(分)", s.timeToEmptyMinutes)
        divider()
        p("电池电压(mV)", s.packVoltageMV)
        p("电池电流(mA)", s.packAmperageMA)
        p("电池净功率(mW,遥测)", s.batteryPowerMW)
        p("电芯电压(mV)", s.cellVoltagesMV)
        p("电池温度(°C)", s.batteryTemperatureC)
        divider()
        p("遥测来源", s.telemetrySource.rawValue)
        p("适配器输入(mW)", s.systemPowerInMW)
        p("系统负载(mW)", s.systemLoadMW)
        p("系统电流(mA)", s.systemCurrentInMA)
        p("系统电压(mV)", s.systemVoltageInMV)
        p("适配器损耗(mW)", s.adapterEfficiencyLossMW)
        divider()
        p("适配器名称", s.adapterName)
        p("适配器额定(W)", s.adapterRatedWatts)
        p("适配器协商(mV/mA)", "\(s.adapterNegotiatedVoltageMV.map(String.init) ?? "-") / \(s.adapterNegotiatedCurrentMA.map(String.init) ?? "-")")
        p("PD 档位数", s.adapterPDOMenu.count)
        divider()
        p("充电目标电流(mA)", s.chargingCurrentMA)
        p("充电目标电压(mV)", s.chargingVoltageMV)
        p("未充电原因", s.notChargingReason)
        p("慢充原因", s.slowChargingReason)
        divider()
        p("循环次数", s.cycleCount)
        p("设计循环", s.designCycleCount)
        p("设计容量(mAh)", s.designCapacityMAH)
        p("满充容量(mAh)", s.maxCapacityMAH)
        p("标称容量(mAh)", s.nominalCapacityMAH)
        p("健康度(%)", s.healthPercent.map { String(format: "%.1f", $0) })
        p("电芯内阻(mΩ)", s.weightRa)
        p("累计使用(分)", s.lifetimeOperatingMinutes)
        divider()
        p("电量计刷新时间", s.gaugeUpdateTime.map { "\($0)" })
        p("距刷新(秒)", s.secondsSinceGaugeUpdate)
        divider()
        p("净功率(W)", s.batteryNetWatts)
        p("电压电流口径(W)", s.packWattsFromVI)
        p("恒等式偏差(W)", s.identityDiscrepancyWatts)
        p("插电净放电", s.isNetDischargingWhilePlugged)
    }

    private static func p(_ label: String, _ value: Any?) {
        let text: String
        if let value {
            text = "\(value)"
        } else {
            text = "nil"
        }
        print("  \(pad(label, 22)) \(text)")
    }

    private static func divider() {
        print("  " + String(repeating: "·", count: 44))
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        let count = s.count
        if count >= width { return s }
        return s + String(repeating: " ", count: width - count)
    }
}
