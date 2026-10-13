# APK v1 signing compatible with Android 2.x-4.2: SHA1, SignerInfo with rsaEncryption, no signed attributes.
import sys, zipfile, hashlib, base64, subprocess, os, tempfile
src, dst, key, cert = sys.argv[1:5]
zin = zipfile.ZipFile(src)
entries = [i for i in zin.infolist() if not i.filename.startswith('META-INF/')]
def b64sha1(b): return base64.b64encode(hashlib.sha1(b).digest()).decode()
def wrap(line):  # manifest lines of at most 72 bytes
    out = []; b = line.encode()
    out.append(b[:70]); b = b[70:]
    while b: out.append(b' ' + b[:69]); b = b[69:]
    return b'\r\n'.join(out) + b'\r\n'
main = b'Manifest-Version: 1.0\r\nCreated-By: 1.0 (Storio DOOM)\r\n\r\n'
mf = main; sections = []
for i in entries:
    sec = wrap('Name: ' + i.filename) + wrap('SHA1-Digest: ' + b64sha1(zin.read(i))) + b'\r\n'
    sections.append((i.filename, sec)); mf += sec
sf = b'Signature-Version: 1.0\r\nCreated-By: 1.0 (Storio DOOM)\r\n' + wrap('SHA1-Digest-Manifest: ' + b64sha1(mf)) + b'\r\n'
for name, sec in sections:
    sf += wrap('Name: ' + name) + wrap('SHA1-Digest: ' + b64sha1(sec)) + b'\r\n'
td = tempfile.mkdtemp()
open(td + '/CERT.SF', 'wb').write(sf)
subprocess.check_call(['openssl', 'smime', '-sign', '-in', td + '/CERT.SF', '-signer', cert, '-inkey', key,
                       '-binary', '-noattr', '-md', 'sha1', '-outform', 'DER', '-out', td + '/CERT.RSA'])
with zipfile.ZipFile(dst, 'w') as z:
    z.writestr(zipfile.ZipInfo('META-INF/MANIFEST.MF', (2015,1,1,0,0,0)), mf, zipfile.ZIP_DEFLATED)
    z.writestr(zipfile.ZipInfo('META-INF/CERT.SF', (2015,1,1,0,0,0)), sf, zipfile.ZIP_DEFLATED)
    z.writestr(zipfile.ZipInfo('META-INF/CERT.RSA', (2015,1,1,0,0,0)), open(td + '/CERT.RSA', 'rb').read(), zipfile.ZIP_DEFLATED)
    for i in entries:
        zi = zipfile.ZipInfo(i.filename, (2015,1,1,0,0,0)); zi.compress_type = i.compress_type
        z.writestr(zi, zin.read(i))
print('signed', dst)
