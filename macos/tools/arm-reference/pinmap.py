#!/usr/bin/env python3
"""Generates Sources/CortexM4/stm32_pins.inc: which bus signal (SPI, I2S, I2C, USART) each pin of the modelled STM32s'
packages carries through which alternate function (the F405's and F373's AF numbers) or remap (the F103's AFIO_MAPR),
from ST's own pin data (github.com/STMicroelectronics/STM32_open_pin_data, BSD-3-Clause, the database STM32CubeMX
uses).

    python3 pinmap.py [cache directory]

The files are downloaded once into the cache directory (default: $TMPDIR/stm32-pin-data)."""

import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

BASE = "https://raw.githubusercontent.com/STMicroelectronics/STM32_open_pin_data/master/mcu/"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Sources", "CortexM4", "stm32_pins.inc")

# the model (STM32Model), its MCU file and its pins as the model's package has them
CHIPS = [
    ("STM32_F405", "STM32F405RGTx", [(p, n) for p in "ABC" for n in range(16)] + [("D", 2)]),
    ("STM32_F373", "STM32F373R(8-B-C)Tx", [(p, n) for p in "ABC" for n in range(16)]
     + [("D", 8), ("E", 8), ("E", 9), ("F", 6), ("F", 7)]),
    ("STM32_F103", "STM32F103C(8-B)Tx", [(p, n) for p in "AB" for n in range(16)] + [("C", 13), ("C", 14), ("C", 15)]),
]

# signal name -> (peripheral kind, role)
ROLES = {
    "SCK": ("SPI", "SCK"), "MISO": ("SPI", "MISO"), "MOSI": ("SPI", "MOSI"), "NSS": ("SPI", "NSS"),
    "CK": ("SPI", "SCK"), "SD": ("SPI", "MOSI"), "WS": ("SPI", "NSS"), "MCK": ("SPI", "MCK"),
    "ext_SD": ("SPI", "EXTSD"),
    "SCL": ("I2C", "SCL"), "SDA": ("I2C", "SDA"),
    "TX": ("USART", "TX"), "RX": ("USART", "RX"),
}
# the F103's remaps: the AFIO_MAPR field each peripheral's remap block names (its shift and width)
F1_REMAP_FIELDS = {"SPI1": (0, 1), "I2C1": (1, 1), "USART1": (2, 1), "USART2": (3, 1), "USART3": (4, 2)}


def fetch(cache, name):
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        url = BASE + urllib.parse.quote(name)
        with urllib.request.urlopen(url) as response, open(path, "wb") as out:
            out.write(response.read())
    return path


def strip(tag):
    return tag.split("}")[-1]


def parse_signal(name):
    """('SPI', 2, 'SCK') for SPI2_SCK or I2S2_CK; (kind, instance, role) or None"""
    m = re.match(r"^(SPI|I2S|I2C|USART|UART)(\d)(?:_ext)?_(\w+)$", name)
    if not m:
        return None
    peripheral, instance, role = m.group(1), int(m.group(2)), m.group(3)
    if "_ext_" in name:
        role = "ext_" + role
    if role not in ROLES:
        return None
    kind, role = ROLES[role]
    if peripheral in ("SPI", "I2S") and kind != "SPI":
        return None
    if peripheral in ("USART", "UART") and kind != "USART":
        return None
    if peripheral == "I2C" and kind != "I2C":
        return None
    return kind, instance, role


def main():
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "stm32-pin-data")
    os.makedirs(cache, exist_ok=True)
    rows = []
    for model, mcu, pins in CHIPS:
        tree = ET.parse(fetch(cache, mcu + ".xml"))
        version = None
        for ip in tree.getroot():
            if strip(ip.tag) == "IP" and ip.get("Name") == "GPIO":
                version = ip.get("Version")
        modes = ET.parse(fetch(cache, "IP/GPIO-" + version + "_Modes.xml")).getroot()
        by_pin = {}
        for element in modes:
            if strip(element.tag) == "GPIO_Pin":
                by_pin.setdefault(element.get("Name"), element)
        # the MCU file's own list of each pin's signals: on the F103, those its modes file leaves out (no remap to
        # choose: SPI2's, I2C2's) are always there
        listed = {}
        for pin in tree.getroot():
            if strip(pin.tag) == "Pin":
                listed[pin.get("Name")] = [s.get("Name") for s in pin if strip(s.tag) == "Signal"]
        for port, number in pins:
            name = "P%s%d" % (port, number)
            element = by_pin.get(name)
            if model == "STM32_F103":
                in_modes = set() if element is None else \
                    {s.get("Name") for s in element if strip(s.tag) == "PinSignal"}
                for signal_name in listed.get(name, []):
                    parsed = parse_signal(signal_name)
                    if parsed and signal_name not in in_modes:
                        kind, instance, role = parsed
                        rows.append((model, port, number, -1, -1, 0, kind, instance, role))
            if element is None:
                continue
            for signal in element:
                if strip(signal.tag) != "PinSignal":
                    continue
                parsed = parse_signal(signal.get("Name"))
                if not parsed:
                    continue
                kind, instance, role = parsed
                if model != "STM32_F103":
                    for value in signal.iter():
                        if strip(value.tag) == "PossibleValue":
                            m = re.match(r"GPIO_AF(\d+)_", value.text or "")
                            if m:
                                rows.append((model, port, number, int(m.group(1)), -1, 0, kind, instance, role))
                    continue
                # the F103: the remap block (its value in its AFIO_MAPR field), or none (always there)
                blocks = [b for b in signal if strip(b.tag) == "RemapBlock"]
                peripheral = signal.get("Name").split("_")[0]
                field = F1_REMAP_FIELDS.get(peripheral)
                if not blocks or field is None:
                    rows.append((model, port, number, -1, -1, 0, kind, instance, role))
                    continue
                for block in blocks:
                    m = re.search(r"_REMAP(\d+)$", block.get("Name"))
                    if m:
                        rows.append((model, port, number, -1, field[0], int(m.group(1)), kind, instance, role))
    rows = sorted(set(rows), key=lambda r: (r[0], r[1], r[2], r[6], r[7], r[8], r[3], r[5]))
    ports = {p: i for i, p in enumerate("ABCDEFGHI")}
    with open(OUT, "w") as out:
        out.write("// Generated by tools/arm-reference/pinmap.py from STMicroelectronics' STM32_open_pin_data (the pin\n"
                  "// database STM32CubeMX uses): the bus signals each pin of the modelled packages carries, by alternate\n"
                  "// function (af) or, on the F103, by its remap (the AFIO_MAPR field at `remap_shift` holding `remap`).\n"
                  "//\n"
                  "// Copyright (c) 2020, STMicroelectronics. All rights reserved. Redistributed under the BSD 3-Clause\n"
                  "// License: redistribution and use in source and binary forms, with or without modification, are\n"
                  "// permitted provided that the copyright notice, this list of conditions and the following disclaimer\n"
                  "// are retained; neither the name of the copyright holder nor the names of its contributors may be used\n"
                  "// to endorse or promote products derived from this software without specific prior written permission.\n"
                  "// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR\n"
                  "// IMPLIED WARRANTIES ARE DISCLAIMED.\n\n")
        for model, port, number, af, shift, remap, kind, instance, role in rows:
            out.write("    {%s, %d, %d, %d, %d, %d, PIN_%s, %d, ROLE_%s},\n"
                      % (model, ports[port], number, af, shift, remap, kind, instance, role))
    print("%d rows -> %s" % (len(rows), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
