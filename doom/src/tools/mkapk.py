import struct, sys, os, zipfile
ANDROID_NS = "http://schemas.android.com/apk/res/android"
RID = {'theme':0x01010000,'label':0x01010001,'name':0x01010003,'hasCode':0x0101000c,'launchMode':0x0101001d,
       'screenOrientation':0x0101001e,'configChanges':0x0101001f,'value':0x01010024,'minSdkVersion':0x0101020c,
       'versionCode':0x0101021b,'versionName':0x0101021c,'targetSdkVersion':0x01010270}
T_REF, T_STR, T_DEC, T_HEX, T_BOOL = 0x01, 0x03, 0x10, 0x11, 0x12

def A(name, typ, val, ns=True): return (name, typ, val, ns)
manifest = ('manifest', [A('versionCode',T_DEC,8), A('versionName',T_STR,'1.7'), A('package',T_STR,'org.storio.doom',False)], [
  ('uses-sdk', [A('minSdkVersion',T_DEC,17), A('targetSdkVersion',T_DEC,17)], []),
  ('uses-permission', [A('name',T_STR,'android.permission.READ_EXTERNAL_STORAGE')], []),
  ('uses-permission', [A('name',T_STR,'android.permission.WRITE_EXTERNAL_STORAGE')], []),
  ('uses-permission', [A('name',T_STR,'android.permission.INTERNET')], []),
  ('application', [A('label',T_STR,'DOOM'), A('hasCode',T_BOOL,False)], [
    ('activity', [A('theme',T_REF,0x01030007), A('label',T_STR,'DOOM'), A('name',T_STR,'android.app.NativeActivity'),
                  A('launchMode',T_DEC,2), A('screenOrientation',T_DEC,0), A('configChanges',T_HEX,0x5f0)], [
      ('meta-data', [A('name',T_STR,'android.app.lib_name'), A('value',T_STR,'doom')], []),
      ('intent-filter', [], [
        ('action', [A('name',T_STR,'android.intent.action.MAIN')], []),
        ('category', [A('name',T_STR,'android.intent.category.LAUNCHER')], []),
      ]),
    ]),
  ]),
])

def build_axml(root):
    # strings: first the attribute names that have a resource id (in map order), then the rest
    attr_names = []
    def walk(n):
        for a in n[1]:
            if a[3] and a[0] not in attr_names: attr_names.append(a[0])
        for c in n[2]: walk(c)
    walk(root)
    strings = list(attr_names)
    def add(s):
        if s not in strings: strings.append(s)
        return strings.index(s)
    for s in ['android', ANDROID_NS]: add(s)
    def collect(n):
        add(n[0])
        for a in n[1]:
            add(a[0])
            if a[1] == T_STR: add(a[2])
        for c in n[2]: collect(c)
    collect(root)
    # string pool UTF-16
    data = b''; offs = []
    for s in strings:
        offs.append(len(data)); e = s.encode('utf-16-le'); data += struct.pack('<H', len(s)) + e + b'\0\0'
    while len(data) % 4: data += b'\0'
    hdr = 28; sp_start = hdr + 4*len(strings)
    sp = struct.pack('<HHIIIIII', 0x0001, hdr, sp_start + len(data), len(strings), 0, 0, sp_start, 0)
    sp += struct.pack('<%dI' % len(strings), *offs) + data
    rm = struct.pack('<HHI', 0x0180, 8, 8 + 4*len(attr_names)) + struct.pack('<%dI' % len(attr_names), *[RID[n] for n in attr_names])
    body = b''
    nsi, urii = strings.index('android'), strings.index(ANDROID_NS)
    body += struct.pack('<HHIIiii', 0x0100, 16, 24, 1, -1, nsi, urii)
    def emit(n):
        nonlocal body
        attrs = []
        for (name, typ, val, ns) in n[1]:
            if typ == T_STR: raw = strings.index(val); data_ = raw
            elif typ == T_BOOL: raw = -1; data_ = 0xffffffff if val else 0
            else: raw = -1; data_ = val
            attrs.append((urii if ns else -1, strings.index(name), raw, typ, data_))
        attrs.sort(key=lambda a: RID.get(strings[a[1]], 0xffffffff) if a[0] != -1 else 0xffffffff)
        ab = b''.join(struct.pack('<iiiHBBI', a[0], a[1], a[2], 8, 0, a[3], a[4] & 0xffffffff) for a in attrs)
        body += struct.pack('<HHIIiiiHHHHHH', 0x0102, 16, 36 + len(ab), 1, -1, -1, strings.index(n[0]), 20, 20, len(attrs), 0, 0, 0) + ab
        for c in n[2]: emit(c)
        body += struct.pack('<HHIIiii', 0x0103, 16, 24, 1, -1, -1, strings.index(n[0]))
    emit(root)
    body += struct.pack('<HHIIiii', 0x0101, 16, 24, 1, -1, nsi, urii)
    payload = sp + rm + body
    return struct.pack('<HHI', 0x0003, 8, 8 + len(payload)) + payload

def empty_pool():
    return struct.pack('<HHIIIIII', 0x0001, 28, 28, 0, 0, 0, 28, 0)

def build_arsc(pkgname, pkgid=0x7f):
    name = pkgname.encode('utf-16-le').ljust(256, b'\0')
    tsp = empty_pool(); ksp = empty_pool()
    hs = 288
    pkg = struct.pack('<HHII', 0x0200, hs, hs + len(tsp) + len(ksp), pkgid) + name + struct.pack('<IIII', hs, 0, hs + len(tsp), 0)
    pkg = pkg.ljust(hs, b'\0') + tsp + ksp
    g = empty_pool()
    return struct.pack('<HHII', 0x0002, 12, 12 + len(g) + len(pkg), 1) + g + pkg

if __name__ == '__main__':
    out, lib = sys.argv[1], sys.argv[2]
    assets = sys.argv[3:]
    ax = build_axml(manifest)
    open(os.path.join(os.path.dirname(os.path.abspath(out)), 'AndroidManifest.xml'), 'wb').write(ax)
    with zipfile.ZipFile(out, 'w') as z:
        z.writestr(zipfile.ZipInfo('AndroidManifest.xml', (2015,1,1,0,0,0)), ax, zipfile.ZIP_DEFLATED)
        z.writestr(zipfile.ZipInfo('resources.arsc', (2015,1,1,0,0,0)), build_arsc('org.storio.doom'), zipfile.ZIP_STORED)
        z.write(lib, 'lib/armeabi-v7a/libdoom.so', zipfile.ZIP_DEFLATED)
        for a in assets:
            z.write(a, 'assets/' + os.path.basename(a), zipfile.ZIP_STORED)
