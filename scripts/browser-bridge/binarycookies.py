"""Lists cookies in a WebKit .binarycookies file: domain, name, times, flags. Never prints values.

Usage: binarycookies.py <file> [host-substring]
"""
import struct, sys, datetime
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'cook', d[:4]
n = struct.unpack('>i', d[4:8])[0]
sizes = struct.unpack('>' + 'i'*n, d[8:8+4*n])
off = 8 + 4*n
for size in sizes:
    page = d[off:off+size]; off += size
    count = struct.unpack('<i', page[4:8])[0]
    offs = struct.unpack('<' + 'i'*count, page[8:8+4*count])
    for o in offs:
        c = page[o:]
        flags = struct.unpack('<i', c[8:12])[0]
        uo, no, po, vo = struct.unpack('<iiii', c[16:32])
        exp = struct.unpack('<d', c[40:48])[0]
        cre = struct.unpack('<d', c[48:56])[0]
        s = lambda a: c[a:c.index(b'\0', a)].decode(errors='replace')
        t = lambda x: datetime.datetime.fromtimestamp(x + 978307200).strftime('%Y-%m-%d %H:%M:%S')
        if len(sys.argv) > 2 and sys.argv[2] not in s(uo):
            continue
        print(f"{s(uo):28} {s(no):34} created={t(cre)} expires={t(exp)} flags={flags} valuelen={len(s(vo))}")
