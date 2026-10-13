// StorioTool core - compatible with C# 5 / .NET Framework 4.x (PowerShell 5.1)
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace StorioTool
{
    public static class Native
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, out long outBuf, uint outSize, out uint returned, IntPtr ov);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "DeviceIoControl")]
        public static extern bool DeviceIoControlNoBuf(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint returned, IntPtr ov);

        public const uint GENERIC_READ = 0x80000000;
        public const uint GENERIC_WRITE = 0x40000000;
        public const uint SHARE_RW = 3;
        public const uint OPEN_EXISTING = 3;
        public const uint FLAG_WRITE_THROUGH = 0x80000000;
        public const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
        public const uint FSCTL_LOCK_VOLUME = 0x00090018;
        public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

        public static long GetLength(SafeFileHandle h)
        {
            long len; uint ret;
            if (!DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, out len, 8, out ret, IntPtr.Zero))
                throw new IOException("Could not read the disk size (error " + Marshal.GetLastWin32Error() + ")");
            return len;
        }

        // Locks and dismounts the card volumes so that it can be written to.
        public static List<SafeFileHandle> LockVolumes(string[] volumes)
        {
            List<SafeFileHandle> list = new List<SafeFileHandle>();
            if (volumes == null) return list;
            foreach (string v0 in volumes)
            {
                if (string.IsNullOrEmpty(v0)) continue;
                string v = v0.TrimEnd('\\');
                SafeFileHandle h = CreateFile(v, GENERIC_READ | GENERIC_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (h.IsInvalid) throw new IOException("Could not open volume " + v + " (error " + Marshal.GetLastWin32Error() + ")");
                uint ret;
                bool locked = DeviceIoControlNoBuf(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                DeviceIoControlNoBuf(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                if (!locked) locked = DeviceIoControlNoBuf(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                if (!locked)
                {
                    h.Dispose();
                    foreach (SafeFileHandle o in list) o.Dispose();
                    throw new IOException("Could not lock volume " + v + ". Close any File Explorer window that has the card open.");
                }
                list.Add(h);
            }
            return list;
        }
    }

    // Access to a physical disk or an image file with sector-aligned reads.
    public class Dev : IDisposable
    {
        public FileStream S;
        public long Length;
        public string Path;
        List<SafeFileHandle> locks = new List<SafeFileHandle>();
        const int SEC = 512;

        public static bool IsRaw(string p) { return p.StartsWith(@"\\.\"); }

        public static Dev Open(string path, bool write, long knownLength, string[] lockVolumes)
        {
            Dev d = new Dev();
            d.Path = path;
            if (IsRaw(path))
            {
                if (write) d.locks = Native.LockVolumes(lockVolumes);
                SafeFileHandle h = Native.CreateFile(path, write ? (Native.GENERIC_READ | Native.GENERIC_WRITE) : Native.GENERIC_READ,
                    Native.SHARE_RW, IntPtr.Zero, Native.OPEN_EXISTING, write ? Native.FLAG_WRITE_THROUGH : 0, IntPtr.Zero);
                if (h.IsInvalid)
                {
                    int err = Marshal.GetLastWin32Error();
                    d.ReleaseLocks();
                    throw new IOException("Could not open " + path + " (error " + err + "). Is it running as administrator?");
                }
                d.S = new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read, 1, false);
                d.Length = knownLength > 0 ? knownLength : Native.GetLength(h);
            }
            else
            {
                d.S = new FileStream(path, FileMode.Open, write ? FileAccess.ReadWrite : FileAccess.Read,
                    write ? FileShare.Read : FileShare.ReadWrite, 1 << 16);
                d.Length = d.S.Length;
            }
            return d;
        }

        void ReleaseLocks()
        {
            foreach (SafeFileHandle h in locks) h.Dispose();
            locks.Clear();
        }

        public void Dispose()
        {
            if (S != null) { try { S.Flush(true); } catch { } S.Dispose(); S = null; }
            ReleaseLocks();
        }

        void RawRead(long off, byte[] buf, int idx, int len)
        {
            S.Seek(off, SeekOrigin.Begin);
            int got = 0;
            while (got < len)
            {
                int n = S.Read(buf, idx + got, len - got);
                if (n <= 0) throw new IOException("Incomplete read at position " + (off + got) + " of " + Path);
                got += n;
            }
        }

        public void ReadAt(long off, byte[] buf, int idx, int len)
        {
            if (off < 0 || off + len > Length) throw new IOException("Read out of range (" + off + "+" + len + ") in " + Path);
            long a0 = off - (off % SEC);
            long a1 = off + len; if (a1 % SEC != 0) a1 += SEC - (a1 % SEC);
            if (a0 == off && a1 == off + len) { RawRead(off, buf, idx, len); return; }
            byte[] tmp = new byte[a1 - a0];
            RawRead(a0, tmp, 0, tmp.Length);
            Buffer.BlockCopy(tmp, (int)(off - a0), buf, idx, len);
        }

        public byte[] Read(long off, int len)
        {
            byte[] b = new byte[len];
            ReadAt(off, b, 0, len);
            return b;
        }

        public void WriteAt(long off, byte[] buf, int idx, int len)
        {
            if (off < 0 || off + len > Length) throw new IOException("Write out of range in " + Path);
            long a0 = off - (off % SEC);
            long a1 = off + len; if (a1 % SEC != 0) a1 += SEC - (a1 % SEC);
            byte[] tmp;
            if (a0 == off && a1 == off + len) { tmp = new byte[len]; Buffer.BlockCopy(buf, idx, tmp, 0, len); }
            else { tmp = new byte[a1 - a0]; RawRead(a0, tmp, 0, tmp.Length); Buffer.BlockCopy(buf, idx, tmp, (int)(off - a0), len); }
            S.Seek(a0, SeekOrigin.Begin);
            S.Write(tmp, 0, tmp.Length);
            S.Flush(true);
        }
    }

    public class Progress
    {
        string label; long total; Stopwatch sw = Stopwatch.StartNew(); long lastMs = -10000;
        public Progress(string label, long total) { this.label = label; this.total = total; }
        public void Update(long done, bool force)
        {
            long ms = sw.ElapsedMilliseconds;
            if (!force && ms - lastMs < 500) return;
            lastMs = ms;
            double pct = total > 0 ? done * 100.0 / total : 100;
            double mbs = ms > 0 ? (done / 1048576.0) / (ms / 1000.0) : 0;
            string eta = "";
            if (mbs > 0.1 && done < total)
            {
                TimeSpan t = TimeSpan.FromSeconds((total - done) / 1048576.0 / mbs);
                eta = string.Format("  {0}:{1:00} left", (int)t.TotalMinutes, t.Seconds);
            }
            try
            {
                Console.Write("\r  {0}: {1,5:0.0}%  {2:N0} / {3:N0} MB  {4:0.0} MB/s{5}      ",
                    label, pct, done / 1048576, total / 1048576, mbs, eta);
            }
            catch { }
        }
        public void Done() { Update(total, true); try { Console.WriteLine(); } catch { } }
    }

    public class Part
    {
        public string Name;
        public long OffSec;
        public long SizeSec; // -1 = up to the end
        public long Start;   // absolute bytes
        public long Len;     // bytes
        public string Check = "";
    }

    public class Layout
    {
        public long ParmOffset = -1;
        public string ParmText = "";
        public long BaseSec = -1;
        public string Method = "";
        public bool Verified;
        public List<Part> Parts = new List<Part>();
        public Part Get(string name)
        {
            foreach (Part p in Parts) if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase)) return p;
            return null;
        }
    }

    public static class Core
    {
        const int CHUNK = 4 * 1024 * 1024;

        public static string Hex(byte[] h)
        {
            StringBuilder sb = new StringBuilder();
            foreach (byte b in h) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        // Copies (or only reads, if dst is null) a range while computing the SHA-256 of the data.
        public static string CopyHash(Dev src, long srcOff, Dev dst, long dstOff, long len, string label)
        {
            if (len % 512 != 0) throw new IOException("The size is not a multiple of 512 bytes: " + len);
            SHA256 sha = SHA256.Create();
            byte[] buf = new byte[CHUNK];
            Progress pr = new Progress(label, len);
            long done = 0;
            while (done < len)
            {
                int n = (int)Math.Min(CHUNK, len - done);
                src.ReadAt(srcOff + done, buf, 0, n);
                if (dst != null)
                {
                    dst.S.Seek(dstOff + done, SeekOrigin.Begin);
                    dst.S.Write(buf, 0, n);
                }
                sha.TransformBlock(buf, 0, n, null, 0);
                done += n;
                pr.Update(done, false);
            }
            if (dst != null) dst.S.Flush(true);
            sha.TransformFinalBlock(new byte[0], 0, 0);
            pr.Done();
            return Hex(sha.Hash);
        }

        public static string CopyToNewFile(Dev src, long off, long len, string outPath, string label)
        {
            using (FileStream fs = new FileStream(outPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1 << 16))
            {
                fs.SetLength(len);
                Dev d = new Dev(); d.S = fs; d.Length = len; d.Path = outPath;
                string h = CopyHash(src, off, d, 0, len, label);
                return h;
            }
        }

        public static string HashFile(string path, string label)
        {
            using (Dev d = Dev.Open(path, false, 0, null))
            {
                long len = d.Length - (d.Length % 512);
                if (len != d.Length) throw new IOException("The file size is not a multiple of 512 bytes; it does not look like a card image.");
                return CopyHash(d, 0, null, 0, len, label);
            }
        }

        public static bool AllZero(byte[] b) { foreach (byte x in b) if (x != 0) return false; return true; }

        // ---------------- Rockchip partition table (PARM block) ----------------

        public static Layout FindParm(Dev d)
        {
            Layout L = new Layout();
            long scan = Math.Min(d.Length, 64L * 1024 * 1024);
            byte[] buf = new byte[1024 * 1024];
            for (long off = 0; off < scan; off += buf.Length)
            {
                int n = (int)Math.Min(buf.Length, scan - off);
                n -= n % 512;
                d.ReadAt(off, buf, 0, n);
                for (int i = 0; i + 8 <= n; i += 512)
                {
                    if (buf[i] == 'P' && buf[i + 1] == 'A' && buf[i + 2] == 'R' && buf[i + 3] == 'M')
                    {
                        int plen = BitConverter.ToInt32(buf, i + 4);
                        if (plen <= 0 || plen > 65536) continue;
                        byte[] t = d.Read(off + i + 8, plen);
                        string text = Encoding.ASCII.GetString(t);
                        if (text.IndexOf("mtdparts", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        L.ParmOffset = off + i;
                        L.ParmText = text.Replace("\0", "");
                        return L;
                    }
                }
            }
            return L;
        }

        public static List<Part> ParseMtdParts(string text)
        {
            List<Part> list = new List<Part>();
            Match mm = Regex.Match(text, @"mtdparts=[^:]+:([^\s]+)");
            string body = mm.Success ? mm.Groups[1].Value : text;
            foreach (Match m in Regex.Matches(body, @"(-|0x[0-9a-fA-F]+)@(0x[0-9a-fA-F]+)\(([^)]+)\)"))
            {
                Part p = new Part();
                p.SizeSec = m.Groups[1].Value == "-" ? -1 : Convert.ToInt64(m.Groups[1].Value.Substring(2), 16);
                p.OffSec = Convert.ToInt64(m.Groups[2].Value.Substring(2), 16);
                p.Name = m.Groups[3].Value;
                list.Add(p);
            }
            return list;
        }

        public static bool IsExt4At(Dev d, long start)
        {
            if (start < 0 || start + 2048 > d.Length) return false;
            byte[] sb = d.Read(start + 1024, 1024);
            return BitConverter.ToUInt16(sb, 56) == 0xEF53;
        }

        public static string BootMagic(Dev d, long start)
        {
            if (start < 0 || start + 8 > d.Length) return "";
            byte[] b = d.Read(start, 8);
            string s = Encoding.ASCII.GetString(b);
            if (s.StartsWith("KRNL")) return "KRNL";
            if (s == "ANDROID!") return "ANDROID!";
            return "";
        }

        static void Place(Dev d, Layout L, long baseSec)
        {
            L.BaseSec = baseSec;
            foreach (Part p in L.Parts)
            {
                p.Start = (baseSec + p.OffSec) * 512;
                if (p.SizeSec >= 0) p.Len = p.SizeSec * 512;
                else p.Len = Math.Max(0, d.Length - p.Start);
                if (p.Start + p.Len > d.Length) p.Len = Math.Max(0, d.Length - p.Start);
                p.Check = "";
                if (IsExt4At(d, p.Start)) p.Check = "ext4";
                else { string bm = BootMagic(d, p.Start); if (bm != "") p.Check = bm; }
            }
        }

        public static Layout Resolve(Dev d)
        {
            Layout L = FindParm(d);
            if (L.ParmOffset >= 0)
            {
                L.Parts = ParseMtdParts(L.ParmText);
                List<long> bases = new List<long>();
                bases.Add(0x2000); bases.Add(L.ParmOffset / 512); bases.Add(0);
                foreach (long b in bases)
                {
                    Place(d, L, b);
                    Part sys = L.Get("system");
                    bool ok = sys != null ? sys.Check == "ext4" : false;
                    if (!ok && sys == null) foreach (Part p in L.Parts) if (p.Check == "ext4") ok = true;
                    if (ok)
                    {
                        L.Verified = true;
                        L.Method = "Rockchip table (PARM at byte " + L.ParmOffset + ", base 0x" + b.ToString("X") + ")";
                        return L;
                    }
                }
                Place(d, L, 0x2000);
                L.Verified = false;
                L.Method = "Rockchip table found but NOT verified (no ext4 found in 'system')";
                return L;
            }
            // No PARM block: known offsets from the SpiffyHacks forum / DSchndr's script
            L.Parts = new List<Part>();
            Part boot = new Part(); boot.Name = "boot"; boot.OffSec = 0xC000; boot.SizeSec = 0x6000; L.Parts.Add(boot);
            Part sy = new Part(); sy.Name = "system"; sy.OffSec = 0x88000; sy.SizeSec = 0x300000; L.Parts.Add(sy);
            Place(d, L, 0);
            L.Verified = sy.Check == "ext4";
            L.Method = L.Verified ? "known offsets (SpiffyHacks forum), verified" : "could NOT locate the partition table";
            return L;
        }

        // ---------------- default.prop inside the boot partition ----------------

        public static string BootDefaultProp(Dev d, Part p)
        {
            byte[] head = d.Read(p.Start, 4096);
            byte[] gz = null;
            string magic = Encoding.ASCII.GetString(head, 0, 8);
            if (magic.StartsWith("KRNL"))
            {
                int size = BitConverter.ToInt32(head, 4);
                if (size <= 0 || size > p.Len) return null;
                gz = d.Read(p.Start + 8, size);
            }
            else if (magic == "ANDROID!")
            {
                int ksize = BitConverter.ToInt32(head, 8);
                int rsize = BitConverter.ToInt32(head, 16);
                int page = BitConverter.ToInt32(head, 36);
                if (page <= 0 || page > 65536) page = 2048;
                long kpages = (ksize + page - 1) / page;
                long roff = page * (1 + kpages);
                if (rsize <= 0 || roff + rsize > p.Len) return null;
                gz = d.Read(p.Start + roff, rsize);
            }
            else return null;
            if (gz.Length < 2 || gz[0] != 0x1f || gz[1] != 0x8b) return null;
            byte[] cpio;
            using (MemoryStream ms = new MemoryStream(gz))
            using (GZipStream g = new GZipStream(ms, CompressionMode.Decompress))
            using (MemoryStream o = new MemoryStream())
            {
                byte[] b = new byte[65536]; int n;
                try { while ((n = g.Read(b, 0, b.Length)) > 0) o.Write(b, 0, n); } catch (InvalidDataException) { }
                cpio = o.ToArray();
            }
            int pos = 0;
            while (pos + 110 <= cpio.Length)
            {
                string h = Encoding.ASCII.GetString(cpio, pos, 110);
                if (!h.StartsWith("07070")) break;
                int fsize = Convert.ToInt32(h.Substring(54, 8), 16);
                int nsize = Convert.ToInt32(h.Substring(94, 8), 16);
                string name = Encoding.ASCII.GetString(cpio, pos + 110, Math.Max(0, nsize - 1));
                int dataPos = (pos + 110 + nsize + 3) & ~3;
                if (name == "TRAILER!!!") break;
                if (name == "default.prop" || name == "./default.prop")
                    return Encoding.GetEncoding(28591).GetString(cpio, dataPos, Math.Min(fsize, cpio.Length - dataPos));
                pos = (dataPos + fsize + 3) & ~3;
            }
            return null;
        }

        // ---------------- build.prop ----------------

        public static string PatchBuildProp(string text, out string changes)
        {
            string nl = "\n";
            List<string> lines = new List<string>(text.Replace("\r\n", "\n").Split('\n'));
            if (lines.Count > 0 && lines[lines.Count - 1] == "") lines.RemoveAt(lines.Count - 1);
            StringBuilder ch = new StringBuilder();
            bool usb = false, en = false, dbg = false;
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i];
                string t = l.Trim();
                if (t.StartsWith("#")) continue;
                if (t.StartsWith("persist.sys.usb.config="))
                {
                    usb = true;
                    string v = t.Substring("persist.sys.usb.config=".Length).Trim();
                    if (("," + v + ",").IndexOf(",adb,") < 0)
                    {
                        string nv = v.Length == 0 || v == "none" ? "adb" : v + ",adb";
                        lines[i] = "persist.sys.usb.config=" + nv;
                        ch.AppendLine("  " + t + "  ->  " + lines[i]);
                    }
                }
                else if (t.StartsWith("persist.service.adb.enable="))
                {
                    en = true;
                    if (t != "persist.service.adb.enable=1") { lines[i] = "persist.service.adb.enable=1"; ch.AppendLine("  " + t + "  ->  " + lines[i]); }
                }
                else if (t.StartsWith("persist.service.debuggable="))
                {
                    dbg = true;
                    if (t != "persist.service.debuggable=1") { lines[i] = "persist.service.debuggable=1"; ch.AppendLine("  " + t + "  ->  " + lines[i]); }
                }
            }
            if (!usb) { lines.Add("persist.sys.usb.config=mtp,adb"); ch.AppendLine("  + persist.sys.usb.config=mtp,adb"); }
            if (!en) { lines.Add("persist.service.adb.enable=1"); ch.AppendLine("  + persist.service.adb.enable=1"); }
            if (!dbg) { lines.Add("persist.service.debuggable=1"); ch.AppendLine("  + persist.service.debuggable=1"); }
            changes = ch.ToString();
            return string.Join(nl, lines.ToArray()) + nl;
        }

        // ---------------- Settings saved in /data/property ----------------

        public static Dictionary<string, string> ReadPersist(Dev d, long partStart)
        {
            Dictionary<string, string> r = new Dictionary<string, string>();
            Ext4 fs = new Ext4(d, partStart);
            uint dir = fs.Lookup("/property");
            if (dir == 0) return null;
            Encoding enc = Encoding.GetEncoding(28591);
            foreach (KeyValuePair<string, uint> kv in fs.ListDir(dir))
            {
                if (kv.Key == "." || kv.Key == "..") continue;
                try { r[kv.Key] = enc.GetString(fs.ReadFile(kv.Value)); } catch { r[kv.Key] = "(unreadable)"; }
            }
            return r;
        }

        public static string PersistNeedsFix(Dictionary<string, string> p)
        {
            if (p == null) return "";
            StringBuilder sb = new StringBuilder();
            string v;
            if (p.TryGetValue("persist.sys.usb.config", out v) && ("," + v.Trim() + ",").IndexOf(",adb,") < 0)
                sb.Append("persist.sys.usb.config=" + v.Trim() + " ");
            if (p.TryGetValue("persist.service.adb.enable", out v) && v.Trim() != "1")
                sb.Append("persist.service.adb.enable=" + v.Trim() + " ");
            return sb.ToString().Trim();
        }

        public static string PatchPersist(Dev d, long partStart)
        {
            StringBuilder ch = new StringBuilder();
            Ext4 fs = new Ext4(d, partStart);
            uint dir = fs.Lookup("/property");
            if (dir == 0) return "";
            Encoding enc = Encoding.GetEncoding(28591);
            Dictionary<string, uint> files = fs.ListDir(dir);
            uint ino;
            if (files.TryGetValue("persist.sys.usb.config", out ino))
            {
                string v = enc.GetString(fs.ReadFile(ino));
                string t = v.Trim();
                if (("," + t + ",").IndexOf(",adb,") < 0)
                {
                    string nv = (t.Length == 0 || t == "none") ? "adb" : t + ",adb";
                    fs.WriteFileInPlace(ino, enc.GetBytes(nv));
                    ch.AppendLine("  /property/persist.sys.usb.config: " + t + "  ->  " + nv);
                }
            }
            if (files.TryGetValue("persist.service.adb.enable", out ino))
            {
                string t = enc.GetString(fs.ReadFile(ino)).Trim();
                if (t != "1")
                {
                    fs.WriteFileInPlace(ino, enc.GetBytes("1"));
                    ch.AppendLine("  /property/persist.service.adb.enable: " + t + "  ->  1");
                }
            }
            if (ch.Length > 0)
            {
                string left = PersistNeedsFix(ReadPersist(d, partStart));
                if (left.Length > 0) throw new IOException("Verification of /property failed: " + left);
            }
            return ch.ToString();
        }

        public static string PatchSystemImage(Dev d, long partStart, out string oldText, out string newText)
        {
            Ext4 fs = new Ext4(d, partStart);
            uint ino = fs.Lookup("/build.prop");
            if (ino == 0) throw new IOException("build.prop was not found in the system partition.");
            Encoding enc = Encoding.GetEncoding(28591);
            oldText = enc.GetString(fs.ReadFile(ino));
            string changes;
            newText = PatchBuildProp(oldText, out changes);
            if (changes.Length == 0) return "";
            long cap = fs.Capacity(ino);
            if (Encoding.UTF8.GetByteCount(newText) > cap)
            {
                // It does not fit: comment lines (#) are removed to make room, without touching any property.
                StringBuilder sb = new StringBuilder();
                foreach (string l in newText.Split('\n')) if (l.Length > 0 && !l.TrimStart().StartsWith("#")) sb.Append(l).Append('\n');
                newText = sb.ToString();
                changes += "  (comment lines were removed so that it fits)\r\n";
            }
            fs.WriteFileInPlace(ino, enc.GetBytes(newText));
            // Verification: read it again from scratch
            Ext4 fs2 = new Ext4(d, partStart);
            string back = enc.GetString(fs2.ReadFile(fs2.Lookup("/build.prop")));
            if (back != newText) throw new IOException("Verification of the modified build.prop failed.");
            return changes;
        }
    }

    // Minimal ext2/3/4 reader (only what is needed to read and patch build.prop).
    public class Ext4
    {
        Dev d; long start;
        public int BlockSize; uint inodesPerGroup; int inodeSize; int descSize; long gdtOffset;
        public uint FeatCompat, FeatIncompat, FeatRoCompat;
        public string VolumeName = "", LastMounted = "";
        public long BlocksCount;

        public Ext4(Dev d, long start)
        {
            this.d = d; this.start = start;
            byte[] sb = d.Read(start + 1024, 1024);
            if (BitConverter.ToUInt16(sb, 56) != 0xEF53) throw new IOException("The partition is not ext4.");
            BlockSize = 1024 << (int)BitConverter.ToUInt32(sb, 24);
            uint firstData = BitConverter.ToUInt32(sb, 20);
            inodesPerGroup = BitConverter.ToUInt32(sb, 40);
            uint rev = BitConverter.ToUInt32(sb, 76);
            inodeSize = rev >= 1 ? BitConverter.ToUInt16(sb, 88) : 128;
            FeatCompat = BitConverter.ToUInt32(sb, 92);
            FeatIncompat = BitConverter.ToUInt32(sb, 96);
            FeatRoCompat = BitConverter.ToUInt32(sb, 100);
            descSize = (FeatIncompat & 0x80) != 0 ? Math.Max((int)BitConverter.ToUInt16(sb, 254), 32) : 32;
            BlocksCount = BitConverter.ToUInt32(sb, 4);
            if ((FeatIncompat & 0x80) != 0) BlocksCount |= ((long)BitConverter.ToUInt32(sb, 0x150)) << 32;
            VolumeName = Encoding.ASCII.GetString(sb, 120, 16).Replace("\0", "");
            LastMounted = Encoding.ASCII.GetString(sb, 136, 64).Replace("\0", "");
            if ((FeatIncompat & 0x10) != 0) throw new IOException("ext4 with meta_bg is not supported.");
            gdtOffset = (long)(firstData + 1) * BlockSize;
        }

        long Blk(long b) { return start + b * BlockSize; }

        long InodeOffset(uint n)
        {
            uint g = (n - 1) / inodesPerGroup, idx = (n - 1) % inodesPerGroup;
            byte[] desc = d.Read(start + gdtOffset + (long)g * descSize, descSize);
            long table = BitConverter.ToUInt32(desc, 8);
            if (descSize >= 64) table |= ((long)BitConverter.ToUInt32(desc, 0x28)) << 32;
            return Blk(table) + (long)idx * inodeSize;
        }

        public byte[] ReadInode(uint n) { return d.Read(InodeOffset(n), Math.Min(inodeSize, 256)); }

        public static long FileSize(byte[] ino)
        {
            return (long)BitConverter.ToUInt32(ino, 4) | ((long)BitConverter.ToUInt32(ino, 108) << 32);
        }

        // Map: {logical, physical, count, uninitialised}
        public List<long[]> GetMap(byte[] ino)
        {
            List<long[]> map = new List<long[]>();
            uint flags = BitConverter.ToUInt32(ino, 32);
            if ((flags & 0x10000000) != 0) throw new IOException("File with inline data (inline_data) is not supported.");
            byte[] iblock = new byte[60];
            Buffer.BlockCopy(ino, 40, iblock, 0, 60);
            if ((flags & 0x80000) != 0) WalkExtents(iblock, map, 0);
            else
            {
                long logical = 0;
                for (int i = 0; i < 12; i++, logical++)
                {
                    uint b = BitConverter.ToUInt32(iblock, i * 4);
                    if (b != 0) map.Add(new long[] { logical, b, 1, 0 });
                }
                long per = BlockSize / 4;
                WalkIndirect(BitConverter.ToUInt32(iblock, 48), 1, ref logical, per, map);
                WalkIndirect(BitConverter.ToUInt32(iblock, 52), 2, ref logical, per, map);
                WalkIndirect(BitConverter.ToUInt32(iblock, 56), 3, ref logical, per, map);
            }
            return map;
        }

        void WalkIndirect(uint blk, int level, ref long logical, long per, List<long[]> map)
        {
            long span = 1; for (int i = 0; i < level; i++) span *= per;
            if (blk == 0) { logical += span; return; }
            byte[] b = d.Read(Blk(blk), BlockSize);
            for (int i = 0; i < per; i++)
            {
                uint x = BitConverter.ToUInt32(b, i * 4);
                if (level == 1) { if (x != 0) map.Add(new long[] { logical, x, 1, 0 }); logical++; }
                else WalkIndirect(x, level - 1, ref logical, per, map);
            }
        }

        void WalkExtents(byte[] node, List<long[]> map, int guard)
        {
            if (guard > 8) throw new IOException("Extent tree too deep.");
            if (BitConverter.ToUInt16(node, 0) != 0xF30A) throw new IOException("Invalid extent header.");
            int entries = BitConverter.ToUInt16(node, 2);
            int depth = BitConverter.ToUInt16(node, 6);
            for (int i = 0; i < entries; i++)
            {
                int e = 12 + i * 12;
                if (depth == 0)
                {
                    long lb = BitConverter.ToUInt32(node, e);
                    int len = BitConverter.ToUInt16(node, e + 4);
                    long uninit = 0;
                    if (len > 32768) { len -= 32768; uninit = 1; }
                    long pb = ((long)BitConverter.ToUInt16(node, e + 6) << 32) | BitConverter.ToUInt32(node, e + 8);
                    map.Add(new long[] { lb, pb, len, uninit });
                }
                else
                {
                    long leaf = BitConverter.ToUInt32(node, e + 4) | ((long)BitConverter.ToUInt16(node, e + 8) << 32);
                    WalkExtents(d.Read(Blk(leaf), BlockSize), map, guard + 1);
                }
            }
        }

        public byte[] ReadFile(uint n)
        {
            byte[] ino = ReadInode(n);
            long size = FileSize(ino);
            if (size > 64L * 1024 * 1024) throw new IOException("File too large to read here.");
            byte[] data = new byte[size];
            foreach (long[] m in GetMap(ino))
            {
                if (m[3] != 0) continue;
                for (long k = 0; k < m[2]; k++)
                {
                    long lo = (m[0] + k) * BlockSize;
                    if (lo >= size) break;
                    int len = (int)Math.Min(BlockSize, size - lo);
                    d.ReadAt(Blk(m[1] + k), data, (int)lo, len);
                }
            }
            return data;
        }

        public Dictionary<string, uint> ListDir(uint n)
        {
            Dictionary<string, uint> r = new Dictionary<string, uint>();
            byte[] data = ReadFile(n);
            bool ftype = (FeatIncompat & 0x2) != 0;
            for (int blk = 0; blk < data.Length; blk += BlockSize)
            {
                int p = blk;
                int end = Math.Min(blk + BlockSize, data.Length);
                while (p + 8 <= end)
                {
                    uint ino = BitConverter.ToUInt32(data, p);
                    int rec = BitConverter.ToUInt16(data, p + 4);
                    int nl = ftype ? data[p + 6] : BitConverter.ToUInt16(data, p + 6);
                    if (rec < 8) break;
                    if (ino != 0 && nl > 0 && p + 8 + nl <= end)
                    {
                        string name = Encoding.UTF8.GetString(data, p + 8, nl);
                        if (!r.ContainsKey(name)) r[name] = ino;
                    }
                    p += rec;
                }
            }
            return r;
        }

        public uint Lookup(string path)
        {
            uint cur = 2;
            foreach (string part in path.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                Dictionary<string, uint> dir = ListDir(cur);
                if (!dir.ContainsKey(part)) return 0;
                cur = dir[part];
            }
            return cur;
        }

        // Bytes that fit in the blocks already allocated to the file (contiguous from the start).
        public long Capacity(uint n)
        {
            List<long[]> map = GetMap(ReadInode(n));
            long blocks = 0;
            bool found = true;
            while (found)
            {
                found = false;
                foreach (long[] m in map)
                    if (m[3] == 0 && blocks >= m[0] && blocks < m[0] + m[2]) { blocks = m[0] + m[2]; found = true; }
            }
            return blocks * BlockSize;
        }

        // Walks the directory tree: returns lines "size<TAB>path" (folders end in /).
        public List<string> Tree(string root, int maxEntries)
        {
            List<string> outl = new List<string>();
            uint start = Lookup(root);
            if (start == 0) return outl;
            Stack<KeyValuePair<string, uint>> st = new Stack<KeyValuePair<string, uint>>();
            st.Push(new KeyValuePair<string, uint>(root.TrimEnd('/'), start));
            HashSet<uint> seen = new HashSet<uint>();
            while (st.Count > 0 && outl.Count < maxEntries)
            {
                KeyValuePair<string, uint> cur = st.Pop();
                if (!seen.Add(cur.Value)) continue;
                Dictionary<string, uint> dir;
                try { dir = ListDir(cur.Value); } catch { outl.Add("?\t" + cur.Key + "/ (unreadable)"); continue; }
                List<string> names = new List<string>(dir.Keys);
                names.Sort(StringComparer.Ordinal);
                foreach (string n in names)
                {
                    if (n == "." || n == "..") continue;
                    byte[] ino;
                    try { ino = ReadInode(dir[n]); } catch { continue; }
                    int mode = BitConverter.ToUInt16(ino, 0) & 0xF000;
                    string path = cur.Key + "/" + n;
                    if (mode == 0x4000) { outl.Add("-\t" + path + "/"); st.Push(new KeyValuePair<string, uint>(path, dir[n])); }
                    else if (mode == 0x8000) outl.Add(FileSize(ino) + "\t" + path);
                    if (outl.Count >= maxEntries) break;
                }
            }
            return outl;
        }

        public string Features()
        {
            return string.Format("compat=0x{0:X} incompat=0x{1:X} ro_compat=0x{2:X}", FeatCompat, FeatIncompat, FeatRoCompat);
        }

        // Rewrites the contents of a file using ONLY the blocks already allocated to it.
        public void WriteFileInPlace(uint n, byte[] content)
        {
            if ((FeatIncompat & 0x4) != 0) throw new IOException("The file system has a journal pending recovery (needs_recovery). Not modified.");
            if ((FeatIncompat & 0x8) != 0) throw new IOException("External journal is not supported.");
            if ((FeatRoCompat & 0x400) != 0) throw new IOException("The file system uses metadata_csum; this program cannot modify it safely.");
            uint known = 0x2 | 0x40 | 0x80 | 0x200 | 0x4;
            if ((FeatIncompat & ~known) != 0) throw new IOException("ext4 with unknown features (" + Features() + "). Not modified.");
            long ioff = InodeOffset(n);
            byte[] ino = ReadInode(n);
            List<long[]> map = GetMap(ino);
            int need = (content.Length + BlockSize - 1) / BlockSize;
            long[] phys = new long[need];
            for (int i = 0; i < need; i++) phys[i] = -1;
            foreach (long[] m in map)
                for (long k = 0; k < m[2]; k++)
                {
                    long lb = m[0] + k;
                    if (lb < need) { if (m[3] != 0) throw new IOException("Uninitialised blocks in build.prop."); phys[lb] = m[1] + k; }
                }
            for (int i = 0; i < need; i++)
                if (phys[i] < 0) throw new IOException("The new build.prop does not fit in the space the file already occupies (" + content.Length + " bytes). Nothing has been modified.");
            for (int i = 0; i < need; i++)
            {
                byte[] blk = new byte[BlockSize];
                int len = Math.Min(BlockSize, content.Length - i * BlockSize);
                Buffer.BlockCopy(content, i * BlockSize, blk, 0, len);
                d.WriteAt(Blk(phys[i]), blk, 0, BlockSize);
            }
            byte[] sz = BitConverter.GetBytes((uint)content.Length);
            d.WriteAt(ioff + 4, sz, 0, 4);
            d.WriteAt(ioff + 108, new byte[4], 0, 4);
        }
    }
}
