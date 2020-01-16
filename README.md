# cz2

## Overview

This script provides an interface for monitoring and controlling a
Carrier ComfortZone II HVAC system from Linux.

## Pre-Requisites

You'll need an RS-485 connection to your ComfortZone II panel. You can
use a serial-to-USB adapter connected locally (usually via
/dev/ttyUSB0), or a serial-to-network adapter for remote management.
Personally, I use a
[USR-W610](https://amazon.com/gp/product/B00QWYW8E4) in Transparent
Mode, connected via WiFi. The proper serial parameters are 9600,8,N,1.

## Installation

You'll need the following non-core perl modules:

* Data::ParseBinary
* Digest::CRC
* IO::Termios (only if using a local serial connection)
* Params::Validate

Edit the `cz2` script and change the two parameters in the
CONFIGURATION SECTION at the top.

## Usage

Run `cz2` for usage information. The set of features supported is
pretty limited right now.

Carrier doesn't provide documentation on the protocol used by this
system, but several people have helped with reverse-engineering. The
most complete reference is currently on a wiki page of the
[CZII_to_MQTT
project](https://github.com/jwarcd/CZII_to_MQTT/wiki/Interpreting-Data).
More features will be added as I discover additional data fields.

## Contributing

If you'd like to see more features, please help figure out more of the
fields! The `czdiff` script can help. If you send me any fields that
you find, I'll do my best to add support.

You can also help by testing this script with different
configurations. I only have remote access, so the direct serial
connection support is untested. Also, my system has only basic remote
sensors in each zone, not Smart Sensors, so I haven't tested with
those.
