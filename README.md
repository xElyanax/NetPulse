<p align="center">
  <img src="assets/logo.png" width="120" height="120" alt="NetPulse PRO Logo" style="border-radius: 24px;">
  <br>
  <h1 align="center">NetPulse PRO 🌐⚡</h1>
</p>

<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-blue?logo=apple" alt="Platform: macOS"></a>
  <img src="https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%2B%20Intel)-purple" alt="Architecture">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift" alt="Swift"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
</p>

**NetPulse PRO** is a lightweight, high-performance menu bar application for macOS designed to monitor network throughput, bandwidth usage, and per-application network consumption with real-time Swift Charts.

---

## 🚀 Easy 1-Line Installation (Recommended)

Open **Terminal** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/xElyanax/NetPulse/main/install.sh | bash
```

> **Why use this?**  
> Running this command automatically downloads the latest release, places it in `/Applications`, bypasses macOS Gatekeeper quarantine, and launches the app immediately without any warnings.

---

## 📦 Manual Download & Installation

1. Download **[NetPulse.zip](https://github.com/xElyanax/NetPulse/releases/latest/download/NetPulse.zip)**.
2. Double-click `NetPulse.zip` to extract `NetPulse.app`.
3. Drag `NetPulse.app` into your **Applications** folder.

### ⚠️ If macOS says "NetPulse is damaged" or "cannot be opened":

Because NetPulse is an open-source tool without a paid Apple Developer certificate ($99/yr), macOS Gatekeeper flags internet downloads as quarantined. To open it:

- **Option A (Terminal - Fastest):**
  ```bash
  xattr -cr /Applications/NetPulse.app
  ```
  *(Then simply double-click the app to open!)*

- **Option B (System Settings):**
  1. Try to open the app once (click *Cancel* or *OK* when the alert appears).
  2. Open **System Settings > Privacy & Security**.
  3. Scroll down to the **Security** section where it says *"NetPulse was blocked..."*.
  4. Click **Open Anyway** and enter your Mac password.

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
