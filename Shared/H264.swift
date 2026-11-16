import CoreMedia
import Foundation

/// Builds a format description from a `.parameterSets` payload (SPS/PPS, each UInt32 BE length-prefixed).
func makeFormat(_ payload: Data) -> CMVideoFormatDescription? {
    var sets: [Data] = []
    var i = 0
    while i + 4 <= payload.count {
        let len = Int(payload.readBE(at: i))
        i += 4
        guard len > 0, i + len <= payload.count else { return nil }
        sets.append(payload.subdata(in: (payload.startIndex + i)..<(payload.startIndex + i + len)))
        i += len
    }
    guard sets.count >= 2 else { return nil }

    var fmt: CMVideoFormatDescription?
    let pointers = sets.map { d -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
        d.copyBytes(to: p, count: d.count)
        return p
    }
    defer { pointers.forEach { $0.deallocate() } }
    let constPointers = pointers.map { UnsafePointer($0) }
    let sizes = sets.map { $0.count }
    let status = constPointers.withUnsafeBufferPointer { ptrs in
        sizes.withUnsafeBufferPointer { szs in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
    }
    return status == noErr ? fmt : nil
}

/// Wraps one AVCC access unit in a sample buffer that should be shown as soon as it is decoded.
func makeSampleBuffer(_ avcc: Data, _ fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
        let block else { return nil }
    let copied = avcc.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
    }
    guard copied == noErr else { return nil }

    var sb: CMSampleBuffer?
    var size = avcc.count
    guard CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sb
}
