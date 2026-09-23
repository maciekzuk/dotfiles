#!/usr/bin/env swift
//
// Live Wi-Fi signal sampler for wifi-survey.sh — one sample per line on stdout.
//
// Why a long-lived process instead of one call per sample: initialising
// CoreWLAN costs ~230 ms, so shelling out per sample would cap the UI at ~4 fps
// and leave the bar lagging behind your feet. Here that cost is paid once and
// every later sample is essentially free.
//
// Why Swift at all: macOS 26 removed the `airport` binary, `wdutil info`
// requires sudo, and `system_profiler SPAirPortDataType` takes 7-9 s per call
// because it rescans the whole neighbourhood. CoreWLAN is the only fast,
// sudo-free source left.
//
// SSID is deliberately not reported — CWInterface.ssid() returns nil without
// Location Services authorisation, while RSSI/noise/rate need no such grant.
// wifi-survey.sh reads the network name from `ipconfig getsummary en0` instead.
//
// Output: "<rssi> <noise> <txMbps> <channel> <widthMHz> <bandGHz> <phy>"
//         "0 0 0 0 - - -" while the interface is not associated.
// Usage:  wifi-rssi.swift [interval_seconds]   (default 0.25)

import CoreWLAN
import Foundation

let interval = CommandLine.arguments.count > 1
    ? (Double(CommandLine.arguments[1]) ?? 0.25)
    : 0.25

guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write(Data("wifi-rssi: no Wi-Fi interface\n".utf8))
    exit(1)
}

func widthLabel(_ channel: CWChannel?) -> String {
    switch channel?.channelWidth {
    case .some(.width20MHz):  return "20"
    case .some(.width40MHz):  return "40"
    case .some(.width80MHz):  return "80"
    case .some(.width160MHz): return "160"
    default:                  return "-"
    }
}

func bandLabel(_ channel: CWChannel?) -> String {
    switch channel?.channelBand {
    case .some(.band2GHz): return "2.4"
    case .some(.band5GHz): return "5"
    case .some(.band6GHz): return "6"
    default:               return "-"
    }
}

func phyLabel(_ mode: CWPHYMode) -> String {
    switch mode {
    case .mode11a:  return "a"
    case .mode11b:  return "b"
    case .mode11g:  return "g"
    case .mode11n:  return "n"
    case .mode11ac: return "ac"
    case .mode11ax: return "ax"
    default:        return "-"
    }
}

while true {
    let rssi = iface.rssiValue()
    if rssi == 0 {
        // Not associated (or radio off) — report a hole rather than a fake 0 dBm.
        print("0 0 0 0 - - -")
    } else {
        let channel = iface.wlanChannel()
        print("\(rssi) \(iface.noiseMeasurement()) \(Int(iface.transmitRate())) "
            + "\(channel?.channelNumber ?? 0) \(widthLabel(channel)) \(bandLabel(channel)) "
            + "\(phyLabel(iface.activePHYMode()))")
    }
    fflush(stdout)  // stdout is block-buffered into a pipe; the reader needs each line now
    Thread.sleep(forTimeInterval: interval)
}
