/// Which of the private aggregate's input buffers carries the process tap.
///
/// The aggregate lists its main sub-device (the output device the tap follows)
/// and the tap. When that device also has input streams, and a USB headset
/// reports one UID for both directions, the aggregate exposes the device's
/// microphone as an input buffer too. Reading buffer 0 then records the
/// headset microphone as "app audio": the meeting app's voices never arrive,
/// and the local voice lands on both tracks. A device with separate input and
/// output UIDs (AirPods) has no such stream, which is why only some outputs
/// showed it.
///
/// **Assumption, not yet measured:** the tap's stream comes after the
/// sub-devices' streams, so it is the last buffer. The first callback logs every
/// buffer's channel count and the choice, so a recording on an affected device
/// confirms or refutes it (`Audio format:` line, `buffers=[…] tap=N`).
enum TapBufferSelection {
    /// Index of the tap's buffer among `bufferCount` input buffers, or nil
    /// when the callback delivered none.
    static func tapBufferIndex(bufferCount: Int) -> Int? {
        bufferCount > 0 ? bufferCount - 1 : nil
    }
}
