#!/usr/bin/env python3
"""SPI loopback demo on /dev/spidev1.0 (RMIO8/9/10/14).

Short MOSI (RMIO9) to MISO (RMIO10) to see the bytes echoed back, or
wire both ends to a Pico 2 SPI slave that echoes.
"""
import sys
import spidev

BUS, CS = 1, 0

spi = spidev.SpiDev()
spi.open(BUS, CS)
spi.max_speed_hz = 1_000_000
spi.mode = 0

tx = bytes(range(256))
rx = spi.xfer2(tx)
print(f"tx: {tx[:16].hex()}")
print(f"rx: {rx[:16].hex()}")
if rx == tx:
    print("OK: MOSI and MISO are shorted (loopback)")
    sys.exit(0)
else:
    print("mismatch: MOSI and MISO are not shorted, or the slave did not echo")
    sys.exit(1)
