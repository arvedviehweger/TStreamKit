import Foundation

/// A single 188-byte MPEG-TS packet, already validated and split into header
/// fields and payload.
struct TSPacket {
    /// 13-bit packet identifier.
    let pid: UInt16
    /// `payload_unit_start_indicator` — true when this packet begins a new
    /// PSI section or PES packet.
    let payloadUnitStart: Bool
    /// 4-bit continuity counter.
    let continuityCounter: UInt8
    /// Payload bytes (after the adaptation field, if any). May be empty.
    let payload: ArraySlice<UInt8>
}

/// Splits a byte stream into validated 188-byte transport-stream packets.
///
/// The parser buffers partial input across calls, validates the `0x47` sync
/// byte, and resynchronizes by scanning forward when alignment is lost.
final class TSPacketParser {
    static let packetSize = 188
    static let syncByte: UInt8 = 0x47

    private var buffer: [UInt8] = []

    /// Feed freshly received bytes. Returns every complete packet that became
    /// available, in order. Malformed regions are skipped during resync.
    func push(_ bytes: Data) -> [TSPacket] {
        buffer.append(contentsOf: bytes)
        return drain()
    }

    /// Discard any buffered partial data (e.g. on stream restart).
    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func drain() -> [TSPacket] {
        var packets: [TSPacket] = []
        var index = 0
        let size = TSPacketParser.packetSize

        while index + size <= buffer.count {
            if buffer[index] != TSPacketParser.syncByte {
                // Lost alignment — scan forward to the next plausible sync byte.
                guard let next = resyncOffset(from: index) else {
                    // No sync byte in the remaining buffer; drop all but the
                    // tail that could still contain one.
                    index = max(buffer.count - (size - 1), index + 1)
                    break
                }
                index = next
                continue
            }

            if let packet = parse(at: index) {
                packets.append(packet)
            }
            index += size
        }

        if index > 0 {
            buffer.removeFirst(index)
        }
        return packets
    }

    /// Finds the next offset that looks like an aligned sync byte. We require a
    /// second sync byte one packet later to avoid latching onto a `0x47` that
    /// merely appears inside a payload.
    private func resyncOffset(from start: Int) -> Int? {
        let size = TSPacketParser.packetSize
        var i = start
        while i + size <= buffer.count {
            if buffer[i] == TSPacketParser.syncByte {
                let nextSync = i + size
                if nextSync >= buffer.count || buffer[nextSync] == TSPacketParser.syncByte {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    private func parse(at offset: Int) -> TSPacket? {
        let b = buffer
        let transportError = (b[offset + 1] & 0x80) != 0
        if transportError { return nil } // corrupt; demuxer will recover

        let payloadUnitStart = (b[offset + 1] & 0x40) != 0
        let pid = (UInt16(b[offset + 1] & 0x1F) << 8) | UInt16(b[offset + 2])
        let adaptationControl = (b[offset + 3] & 0x30) >> 4
        let continuityCounter = b[offset + 3] & 0x0F

        // adaptation_field_control: 0=reserved, 1=payload only,
        // 2=adaptation only, 3=adaptation + payload.
        var payloadStart = offset + 4
        if adaptationControl == 0b10 || adaptationControl == 0b11 {
            let afLength = Int(b[offset + 4])
            payloadStart = offset + 5 + afLength
        }
        let hasPayload = adaptationControl == 0b01 || adaptationControl == 0b11

        let packetEnd = offset + TSPacketParser.packetSize
        guard hasPayload, payloadStart < packetEnd, payloadStart >= offset + 4 else {
            return TSPacket(pid: pid,
                            payloadUnitStart: payloadUnitStart,
                            continuityCounter: continuityCounter,
                            payload: ArraySlice<UInt8>())
        }

        return TSPacket(pid: pid,
                        payloadUnitStart: payloadUnitStart,
                        continuityCounter: continuityCounter,
                        payload: b[payloadStart..<packetEnd])
    }
}
