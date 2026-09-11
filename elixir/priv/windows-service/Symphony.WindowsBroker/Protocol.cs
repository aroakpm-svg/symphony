using System.Buffers.Binary;
using System.Text.Json;
namespace Symphony.WindowsBroker;
public enum FrameKind : byte { Request = 0, Stdout = 1, Stderr = 2, Stdin = 3, Exit = 4, StdinEnd = 5, Error = 6 }
public readonly record struct BrokerFrame(FrameKind Kind, byte[] Payload);
public static class Frame
{
    public const int MaxPayloadLength = 1024 * 1024;
    public static async ValueTask<BrokerFrame> ReadAsync(Stream stream, CancellationToken token)
    { var header = new byte[5]; await stream.ReadExactlyAsync(header, token); var kind = (FrameKind)header[0]; if (!Enum.IsDefined(kind)) throw new InvalidDataException("frame_kind_invalid"); var length = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(1)); if (length < 0 || length > MaxPayloadLength) throw new InvalidDataException("frame_length_invalid"); var payload = new byte[length]; await stream.ReadExactlyAsync(payload, token); return new(kind, payload); }
    public static async Task WriteAsync(Stream stream, FrameKind kind, ReadOnlyMemory<byte> payload, CancellationToken token)
    { if (payload.Length > MaxPayloadLength) throw new InvalidDataException("frame_length_invalid"); var header = new byte[5]; header[0] = (byte)kind; BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(1), payload.Length); await stream.WriteAsync(header, token); await stream.WriteAsync(payload, token); await stream.FlushAsync(token); }
    public static Task WriteJsonAsync<T>(Stream stream, FrameKind kind, T value, CancellationToken token) => WriteAsync(stream, kind, JsonSerializer.SerializeToUtf8Bytes(value), token);
}
