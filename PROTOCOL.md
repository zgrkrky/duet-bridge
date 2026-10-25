# ApogeeGlue protocol notes

Observed between Apogee Control 2 1.21.55 and ApogeeGlue 1.21.52 on macOS 26,
for interoperability. Nothing here comes from Apogee documentation; treat it as
a best-effort description that may change with any Apogee update.

## Transport

ApogeeGlue (a root LaunchDaemon) listens on `127.0.0.1:53435`. Apogee Control 2,
ApogeeMessenger and ApogeeTalkbackHelper each keep one TCP connection open.
Several clients can be connected at once.

## Framing

Each message is a `juce::InterprocessConnection` frame:

| Bytes | Meaning |
| --- | --- |
| 4 | magic `0xf2b49e2c`, little endian |
| 4 | payload length, little endian |
| n | payload |

The payload is:

```
[type] [size] [crc8(type + size)] [body: size bytes] [crc8(body)]
```

- The top two bits of `type` give the width of `size`: `0x00` = 1 byte,
  `0x40` = 2 bytes, `0x80` = 4 bytes (little endian). The low six bits are the
  message type.
- `crc8` is CRC-8 with polynomial `0x07`, initial value `0`, no reflection
  (CRC-8/SMBUS).

## Message types

| Type | Direction | Body |
| --- | --- | --- |
| `0x21` | client → server | empty; asks for the whole tree |
| `0x26` | server → client | zlib stream of the entire `ValueTree` |
| `0x29` | both | zlib stream of a path; acknowledges a tree transfer |
| `0x24` | both | NUL-terminated path; announces a subtree |
| `0x22` | both | NUL-terminated path, then zlib stream of that subtree |
| `0x03` | both | set one property (below) |
| `0x28` | server → client | level meters, about 20 per second |

A client only needs to send `0x21` and then `0x03` messages. The server does not
echo a property change back to the client that sent it, but forwards it to all
other clients. Sometimes it replies with the value converted to its own type
(see `mute` below).

## Trees

Trees use `juce::ValueTree::writeToStream`: node name (NUL-terminated),
compressed-int property count, properties (name + `juce::var` binary), then
compressed-int child count and the children. The top-level node is `root`:

```
root
├─ dev
│  └─ DuetII<serial>          name, samplerate, keyboardVolumeControls, …
│     ├─ hwin/hwin0, hwin1    inputs: gain, phantom, softLimit, …
│     ├─ hwout
│     │  ├─ hwout0            Main Out: gain, mute, dim, sum, …
│     │  └─ hwout1            HP:       gain, mute, dim, sum, …
│     ├─ swout, mixers, appState, versionTree
└─ Apps
   ├─ ApogeeGlue, ApogeeMessenger, Apogee Talkback helper
   └─ Apogee Control 2        added by Apogee Control 2 itself
```

## Setting a property (`0x03`)

```
[value type] [u32 key, little endian] [value]
```

The key is `juce::String::hashCode()` (32-bit, `hash = hash * 31 + char`) of the
property's path **without** the `root` node, for example:

```
/dev/DuetII<serial>/hwout/hwout0/gain
```

A check value: `"/Apps/Apogee Control 2/showMixer"` hashes to `0xbf812e41`.

Value types seen:

| Type | Value |
| --- | --- |
| `1` | int32, little endian |
| `3` | bool, one byte (`00` / `01`) |
| `4` | double, little endian |
| `5` | NUL-terminated UTF-8 string |

Note that type `3` here carries a value byte, unlike in the tree stream where
`juce::var` uses markers `2`/`3` alone for true/false.

## Outputs

| Property | Type to send | Notes |
| --- | --- | --- |
| `gain` | double | dB, -64 … 0. Glue calls `setOutputAttenuation` and the OLED updates. |
| `mute` | int32 `0`/`1` | Glue echoes it back as a type `3` bool. |
| `dim` | int32 `0`/`1` | |

Physical knob turns arrive as `0x03` messages with the same keys.

## Things that did not work

Setting `/dev/DuetII<serial>/keyboardVolumeControls` to `"1"` (Apogee's own
keyboard volume option) had no effect on the hardware on a Mac mini M4 with
macOS 26.4.
