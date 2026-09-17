// Ported from MrTangLuyao/Bilibili-thread-ripper (MIT), src/range-core.js.
// Byte-range splitting / validation primitives for IDM-style concurrent fetch.
library;

import 'dart:typed_data' show Uint8List;

/// Inclusive byte range [start, end].
class ByteRange {
  const ByteRange(this.start, this.end) : length = end - start + 1;

  final int start;
  final int end;
  final int length;
}

/// Parses `"<start>-<end>"`, e.g. from an MP4 sidx box.
ByteRange? parseByteRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d+)-(\d+)$').firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  if (start == null || end == null || end < start) return null;
  return ByteRange(start, end);
}

/// Parses a `Range: bytes=<start>-<end>` request header.
ByteRange? parseRangeHeader(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes=(\d+)-(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  return parseByteRange('${match.group(1)}-${match.group(2)}');
}

/// Parsed `Content-Range: bytes <start>-<end>/<total>` response header.
class ContentRange {
  const ContentRange(this.start, this.end, this.total)
    : length = end - start + 1;

  final int start;
  final int end;
  final int? total;
  final int length;
}

ContentRange? parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)\/(\d+|\*)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  if (start == null || end == null || end < start) return null;
  final totalRaw = match.group(3)!;
  final total = totalRaw == '*' ? null : int.tryParse(totalRaw);
  if (total != null && total <= end) return null;
  return ContentRange(start, end, total);
}

/// Splits [start, end] into at most [concurrency] pieces, each at least
/// [minChunkBytes] long. Mirrors `splitRange` in range-core.js.
List<ByteRange> splitRange(
  int start,
  int end,
  int concurrency, {
  int minChunkBytes = 128 * 1024,
}) {
  final int length = end - start + 1;
  final int limit = concurrency.clamp(1, 512).toInt();
  final int minimum = minChunkBytes.clamp(32 * 1024, 1 << 62).toInt();
  var count = 1;
  if (length > 0) {
    final int bySize = (length / minimum).ceil();
    count = bySize < limit ? bySize : limit;
    if (count < 1) count = 1;
  }
  final base = length ~/ count;
  final remainder = length % count;
  final pieces = <ByteRange>[];
  var cursor = start;
  for (var i = 0; i < count; i++) {
    final size = base + (i < remainder ? 1 : 0);
    pieces.add(ByteRange(cursor, cursor + size - 1));
    cursor += size;
  }
  return pieces;
}

/// Concatenates [chunks] in order, rejecting length mismatches so a bad
/// sub-range can never silently corrupt playback.
Uint8List concatChunks(List<Uint8List> chunks, int expectedLength) {
  final output = Uint8List(expectedLength);
  var offset = 0;
  for (final chunk in chunks) {
    if (offset + chunk.length > expectedLength) {
      throw RangeError('sub-range exceeds target length');
    }
    output.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  if (offset != expectedLength) {
    throw RangeError('sub-range length mismatch: $offset/$expectedLength');
  }
  return output;
}
