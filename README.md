# NetPulse PRO 🌐⚡

[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2013%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Architecture: Universal Binary](https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-purple)]()
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**NetPulse PRO** is a lightweight, high-performance menu bar application for macOS designed to monitor network throughput, bandwidth usage, and per-application network consumption with real-time Swift Charts.

---

## ✨ Features

- **⚡ Real-Time Speed & Live Minute Chart:**
  - Live 60-second sliding window rendering smooth Catmull-Rom spline curves.
  - Sub-second reactive download and upload speeds directly in your menu bar.

- **📊 Multi-Scale Historical Analytics:**
  - **Hourly:** Breakdown of all 24 hours of the day (`00:00` to `23:00`).
  - **Daily:** 14-day network consumption trends.
  - **Weekly:** 8-week aggregated usage comparisons.
  - **Monthly:** 6-month bandwidth timeline.

- **🔍 Interactive Precision Inspection (Hover & Scrubbing):**
  - Hover over any point or bar on the chart to inspect precise bytes down to the exact byte.
  - Dynamic Glassmorphic Tooltips, vertical cursor guidelines (`RuleMark`), and active bar highlighting.

- **📱 Per-Application Traffic Sampling:**
  - Kernel-level real-time sampling of active macOS processes (`nettop`).
  - Dual-gradient progress bars showing download vs. upload ratios per process.

- **🛡️ Network Interface & VPN Detection:**
  - Distinguishes between physical interfaces (`en0` / Wi-Fi / Ethernet) and secure tunnels (`utun*` / VPN).

- **💎 Native & Lightweight:**
  - Built with pure SwiftUI and Swift Charts.
  - Zero heavy third-party dependencies.
  - Optimized for negligible battery impact (< 0.1% CPU idle).

---

## 🚀 Quick Download & Install

1. Download the latest **[NetPulse.zip](https://github.com/xElyanax/NetPulse/releases/latest)** from GitHub Releases.
2. Unzip the archive to get `NetPulse.app`.
3. Move `NetPulse.app` to your `/Applications` folder (or run it directly).

> [!TIP]
> **First Launch on macOS:**
> Because NetPulse is an open-source project without a paid Apple Developer certificate, macOS Gatekeeper may show a security notice on first launch:
> - **Method 1:** Right-click (or Control-click) `NetPulse.app`, select **Open**, and click **Open** in the dialog.
> - **Method 2:** Or run this quick command in Terminal:
>   ```bash
>   xattr -cr /Applications/NetPulse.app
>   ```

---

## 🛠️ Building from Source

To compile and package NetPulse locally on macOS:

```bash
# Clone the repository
git clone https://github.com/xElyanax/NetPulse.git
cd NetPulse

# Run the universal build script
chmod +x build.sh
./build.sh

# Launch the newly built app
open NetPulse.app
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
