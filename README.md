# Digital Wireless Walkie-Talkie (SDR)

## Overview

This project implements a real-time, half-duplex digital walkie-talkie system using **Ettus USRP B200 software-defined radios (SDRs)** and **MATLAB**. It combines audio digitization, digital modulation and demodulation, frame synchronization, and live link monitoring over a **2.45 GHz wireless channel**.

Instead of transmitting analog audio directly, the system encodes speech into binary frames and sends them using continuous-phase frequency-shift keying (CPFSK). The receiver detects and reconstructs the audio signal while displaying communication performance metrics.

## System Architecture & Key Features

![System Block Diagram](images/block_diagram.png)

- **Source Encoding (ADM):** Uses Adaptive Delta Modulation to encode microphone audio into a 1-bit stream, with a step size that adapts to the input signal.
- **Modulation (CPFSK):** Applies continuous-phase binary FSK with frequency deviations of ±35 kHz to maintain phase continuity between symbols.
- **Demodulation:** Uses non-coherent phase-difference detection without requiring explicit carrier phase recovery.
- **Frame Synchronization:** Includes a repeated Barker-13 preamble in each frame and uses matched filtering for frame-start detection.
- **TX/RX Control:** Combines manual Push-to-Talk (PTT) control with Voice Activity Detection (VOX) to manage half-duplex operation and suppress audio during silence.
- **Live Performance Monitoring:** Displays Bit Error Rate (BER), Signal-to-Noise Ratio (SNR), outage probability, preamble correlation peaks, and eye diagrams during operation.

## Hardware & System Specifications

| Parameter | Value |
| --- | --- |
| SDR hardware | Ettus USRP B200 |
| Carrier frequency | 2.45 GHz |
| Baseband sample rate | 400 kS/s |
| Bit rate | 50 kbps |
| Audio sample rate | 8 kHz |
| Frame duration | 0.05 s (2,500 bits) |
| Audio payload | 2,400 bits |

## Frame Structure

Each transmitted frame contains **2,500 bits**, organized as follows:

```text
+----------------------+-------------+-----------------+--------------------+
| Barker Preamble (52) | Test Bits   | Voice Flag      | ADM Payload        |
|                      | (16 bits)   | (32 bits)       | (2,400 bits)       |
+----------------------+-------------+-----------------+--------------------+
```

The frame duration is **50 ms** at a bit rate of **50 kbps**.

## Prerequisites

- MATLAB R2026a (used for development; compatibility with earlier releases is not guaranteed)
- Communications Toolbox
- Audio Toolbox
- Communications Toolbox Support Package for USRP Radio
- Ettus USRP B200 connected via USB 3.0

## Usage

1. Connect the USRP B200 to the host computer using USB 3.0.
2. Open MATLAB and run `src/walkie_talkie.m`.
3. Click the **Live Metrics** figure to give it keyboard focus.
4. Hold **Space** to enable Push-to-Talk (PTT) and speak into the microphone.
5. Release **Space** to return to receive mode.

> **Note:** The block diagram is referenced at `images/block_diagram.png`. Make sure the image exists at this relative path in your repository.
