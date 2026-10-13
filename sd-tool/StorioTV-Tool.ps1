#requires -Version 5.1
<#
  Storio TV / InnoTV - Tool for the internal microSD card
  - Full verified backup (SHA-256)
  - Analysis: Rockchip partition table, firmware version, ADB status
  - Partition extraction
  - Creation of a system partition with ADB enabled (never touches the backup)
  - Writing a partition or a full restore, with checks and verification
  Use at your own risk. Always make the backup first (option 1).
#>
param([switch]$NoMenu)

$ErrorActionPreference = 'Stop'
$Script:ToolVersion = '1.2'
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = $HOME }
$Script:WorkDir = Join-Path $docs 'StorioTV'

$CoreSource = @'
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
'@

if (-not ('StorioTool.Core' -as [type])) {
    Add-Type -TypeDefinition $CoreSource -Language CSharp
}

# ------------------------------------------------------------------ utilities

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Fmt([long]$b) { if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } else { '{0:N1} MB' -f ($b / 1MB) } }
function Pause-Tool { [void](Read-Host "`n  Press Enter to return to the menu") }

function Confirm-Danger([string]$what) {
    Say ''
    Say "  WARNING: $what" Yellow
    Say '  Type WRITE (in capitals) to continue, or press Enter to cancel.' Yellow
    $a = Read-Host '  '
    return ($a -ceq 'WRITE')
}

function Confirm-Yes([string]$q) {
    $a = Read-Host "  $q (y/n)"
    return ($a -match '^(y|yes)$')
}

function Get-FreeSpace([string]$path) {
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch { return [long]::MaxValue }
}

function Read-Sidecar([string]$img) {
    $f = "$img.sha256"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $line = (Get-Content -LiteralPath $f -TotalCount 1)
    if ($line -match '^([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    return $null
}

function Write-Sidecar([string]$file, [string]$hash) {
    Set-Content -LiteralPath "$file.sha256" -Value ("{0} *{1}" -f $hash, (Split-Path -Leaf $file)) -Encoding ASCII
}

function Get-Props([string]$text) {
    $h = [ordered]@{}
    if (-not $text) { return $h }
    foreach ($l in ($text -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
    }
    return $h
}

function Select-File([string]$title, [string]$initialDir) {
    if ($IsLinux -or $IsMacOS) { return (Read-Host "  $title (path)").Trim('"') }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $title
        $dlg.Filter = 'Card / partition images (*.img)|*.img|All files (*.*)|*.*'
        if ($initialDir -and (Test-Path -LiteralPath $initialDir)) { $dlg.InitialDirectory = $initialDir }
        $r = $dlg.ShowDialog($owner)
        $owner.Dispose()
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return $null
    } catch {
        $p = Read-Host "  $title (type the full path)"
        if ($p) { return $p.Trim('"') }
        return $null
    }
}

function Get-LatestBackup {
    if (-not (Test-Path -LiteralPath $Script:WorkDir)) { return $null }
    Get-ChildItem -LiteralPath $Script:WorkDir -Filter '*.img' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'backup_*' -and (Test-Path -LiteralPath ($_.FullName + '.sha256')) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Select-Backup([string]$title) {
    $last = Get-LatestBackup
    if ($last) {
        Say "  Latest verified backup: $($last.Name)  ($(Fmt $last.Length))" Cyan
        if (Confirm-Yes 'Use this backup?') { return $last.FullName }
    }
    $p = Select-File $title $Script:WorkDir
    if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
    Say '  No file was selected.' Yellow
    return $null
}

# ------------------------------------------------------------------ card

function Get-CardVolumes([int]$n) {
    $paths = @()
    foreach ($p in @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
        foreach ($a in @($p.AccessPaths)) { if ($a -like '\\?\Volume*') { $paths += $a } }
    }
    return $paths
}

function Select-Card {
    Say '  Looking for cards...' Cyan
    $all = @(Get-Disk -ErrorAction SilentlyContinue)
    $cands = @($all | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -gt 0 -and $_.Size -le 64GB })
    if ($cands.Count -eq 0) {
        Say '  No card was found. Check that it is inserted in the reader and wait a few seconds.' Red
        Say '  (For safety, the system disk and disks larger than 64 GB are never shown.)' DarkGray
        return $null
    }
    Say ''
    Say '   No.  Size        Bus       Name' White
    foreach ($d in $cands) {
        Say ('   {0,-4} {1,-11} {2,-9} {3}' -f $d.Number, (Fmt $d.Size), $d.BusType, $d.FriendlyName)
    }
    Say ''
    $sel = Read-Host '  Type the No. of the disk that is the Storio card (Enter to cancel)'
    if (-not $sel) { return $null }
    $d = $cands | Where-Object { "$($_.Number)" -eq $sel.Trim() } | Select-Object -First 1
    if (-not $d) { Say '  Invalid number.' Red; return $null }
    if (@('SD', 'USB', 'MMC') -notcontains "$($d.BusType)") {
        Say "  Warning: disk $($d.Number) is connected via '$($d.BusType)', not SD/USB." Yellow
        if (-not (Confirm-Yes 'Are you sure it is the card?')) { return $null }
    }
    if ($d.Size -lt 3.5GB -or $d.Size -gt 16GB) {
        Say "  Warning: the Storio TV card is about 8 GB and this one is $(Fmt $d.Size)." Yellow
        if (-not (Confirm-Yes 'Are you sure it is the right card?')) { return $null }
    }
    return [pscustomobject]@{
        Number = [int]$d.Number
        Path   = "\\.\PhysicalDrive$($d.Number)"
        Size   = [long]$d.Size
        Name   = "$($d.FriendlyName)"
    }
}

# ------------------------------------------------------------------ operations (no prompts)

function Invoke-Backup {
    param([string]$CardPath, [long]$CardSize, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { throw "$OutFile already exists" }
    $free = Get-FreeSpace $OutFile
    if ($free -lt ($CardSize + 200MB)) { throw "Not enough disk space: $(Fmt ($CardSize + 200MB)) needed and $(Fmt $free) available." }

    $src = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        try {
            $h1 = [StorioTool.Core]::CopyToNewFile($src, 0, $src.Length, $OutFile, 'Copying card     ')
        } catch {
            if (Test-Path -LiteralPath $OutFile) { Move-Item -LiteralPath $OutFile -Destination "$OutFile.INCOMPLETE" -Force }
            throw
        }
        Say '  Verification 1/2: re-reading the card...' Cyan
        $h2 = [StorioTool.Core]::CopyHash($src, 0, $null, 0, $src.Length, 'Re-reading card  ')
    } finally { $src.Dispose() }
    if ($h1 -ne $h2) {
        Move-Item -LiteralPath $OutFile -Destination "$OutFile.UNRELIABLE" -Force
        throw 'The two reads of the card do NOT match: the reader or the card is failing. Try another reader/adapter.'
    }
    Say '  Verification 2/2: reading the saved file...' Cyan
    $h3 = [StorioTool.Core]::HashFile($OutFile, 'Checking file')
    if ($h3 -ne $h1) {
        Move-Item -LiteralPath $OutFile -Destination "$OutFile.UNRELIABLE" -Force
        throw 'The saved file does not match the card (PC disk failure).'
    }
    Write-Sidecar $OutFile $h1
    return $h1
}

function Get-Analysis {
    param([string]$Path, [long]$Length = 0)
    $out = New-Object System.Collections.Generic.List[string]
    $res = [ordered]@{ Layout = $null; BuildProp = $null; DefaultProp = $null; Report = $out; AdbReady = $false; PersistFix = @() }
    $d = [StorioTool.Dev]::Open($Path, $false, $Length, $null)
    try {
        $L = [StorioTool.Core]::Resolve($d)
        $res.Layout = $L
        $out.Add("Source:  $Path")
        $out.Add("Size:    $(Fmt $d.Length)  ($($d.Length) bytes)")
        $out.Add("Partitions: $($L.Method)")
        if ($L.ParmText) {
            $cmd = ($L.ParmText -split "`r?`n" | Where-Object { $_ -match 'CMDLINE|MACHINE|MAGIC|FIRMWARE' }) -join "`n         "
            if ($cmd) { $out.Add("PARM:    $cmd") }
        }
        $out.Add('')
        $out.Add('  Partition     Start (sector)    Size          Contents')
        foreach ($p in $L.Parts) {
            $sz = if ($p.SizeSec -lt 0) { "(rest) $(Fmt $p.Len)" } else { Fmt $p.Len }
            $out.Add(('  {0,-13} 0x{1,-14:X} {2,-13} {3}' -f $p.Name, ($p.Start / 512), $sz, $p.Check))
        }
        $out.Add('')

        $sys = $L.Get('system')
        if ($sys -and $sys.Check -eq 'ext4') {
            $fs = New-Object StorioTool.Ext4($d, $sys.Start)
            $out.Add("system: ext4, block $($fs.BlockSize) bytes, $($fs.Features())")
            $ino = $fs.Lookup('/build.prop')
            if ($ino -ne 0) {
                $bytes = $fs.ReadFile($ino)
                $res.BuildProp = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
                $bp = Get-Props $res.BuildProp
                $out.Add('')
                $out.Add('== Firmware version (build.prop) ==')
                $keys = @('ro.build.display.id', 'ro.build.version.incremental', 'ro.build.version.release', 'ro.build.date',
                    'ro.product.model', 'ro.product.brand', 'ro.product.manufacturer', 'ro.product.device', 'ro.build.fingerprint')
                foreach ($k in $keys) { if ($bp.Contains($k)) { $out.Add(('  {0,-32} {1}' -f $k, $bp[$k])) } }
                $extra = 0
                foreach ($k in $bp.Keys) {
                    if ($keys -contains $k) { continue }
                    if ($k -match 'vtech|firmware|fw[._]|sw[._]ver|version' -and $extra -lt 20) {
                        $out.Add(('  {0,-32} {1}' -f $k, $bp[$k])); $extra++
                    }
                }
                $out.Add('')
                $out.Add('== USB / ADB (build.prop) ==')
                foreach ($k in @('persist.sys.usb.config', 'persist.service.adb.enable', 'persist.service.debuggable', 'ro.adb.secure', 'ro.secure', 'ro.debuggable')) {
                    $v = if ($bp.Contains($k)) { $bp[$k] } else { '(not present)' }
                    $out.Add(('  {0,-32} {1}' -f $k, $v))
                }
                $usb = if ($bp.Contains('persist.sys.usb.config')) { $bp['persist.sys.usb.config'] } else { '' }
                $res.AdbReady = ($usb -match '(^|,)adb(,|$)') -and ($bp['persist.service.adb.enable'] -eq '1')
            } else { $out.Add('  build.prop was not found in system.') }
        } else {
            $out.Add('Could not locate the system partition (ext4). Send me this report.')
        }

        $res.PersistFix = @()
        foreach ($pn in @('data', 'userdata')) {
            $dp0 = $L.Get($pn)
            if (-not $dp0 -or $dp0.Check -ne 'ext4') { continue }
            try { $pp = [StorioTool.Core]::ReadPersist($d, $dp0.Start) } catch { $out.Add(''); $out.Add("Could not read '$pn': $($_.Exception.Message)"); continue }
            if ($null -eq $pp) { continue }
            $out.Add('')
            $out.Add("== Settings saved in '$pn' (/property) ==")
            if ($pp.Count -eq 0) { $out.Add('  (empty)') }
            foreach ($k in ($pp.Keys | Sort-Object)) { $out.Add(('  {0,-40} {1}' -f $k, $pp[$k].Trim())) }
            $fix = [StorioTool.Core]::PersistNeedsFix($pp)
            if ($fix) { $res.PersistFix += $pn; $out.Add("  -> This saved setting OVERRIDES build.prop: $fix") }
        }

        $boot = $L.Get('boot')
        if ($boot -and $boot.Check) {
            try { $res.DefaultProp = [StorioTool.Core]::BootDefaultProp($d, $boot) } catch { $res.DefaultProp = $null }
            $out.Add('')
            $out.Add("== boot partition ($($boot.Check)) - default.prop ==")
            if ($res.DefaultProp) {
                $dp = Get-Props $res.DefaultProp
                foreach ($k in @('ro.secure', 'ro.debuggable', 'ro.adb.secure', 'persist.sys.usb.config', 'ro.allow.mock.location')) {
                    $v = if ($dp.Contains($k)) { $dp[$k] } else { '(not present)' }
                    $out.Add(('  {0,-32} {1}' -f $k, $v))
                }
            } else { $out.Add('  Could not read the ramdisk (unrecognised format).') }
        }

        $out.Add('')
        $out.Add('== Conclusion ==')
        if ($res.PersistFix.Count -gt 0) { $out.Add("  There is a saved USB setting in '$($res.PersistFix -join ', ')' that disables ADB: use option 8 as well.") }
        if ($res.AdbReady) { $out.Add('  ADB is already enabled in build.prop.') }
        elseif ($res.BuildProp) { $out.Add('  ADB is DISABLED. Option 6 can create a system partition with ADB enabled.') }
        if ($res.DefaultProp) {
            $dp = Get-Props $res.DefaultProp
            if ($dp['ro.secure'] -eq '1') { $out.Add('  ro.secure=1: with ADB you will get a shell WITHOUT root (enough to install APKs).') }
            if ($dp['ro.adb.secure'] -eq '1') { $out.Add('  ro.adb.secure=1: ADB will ask you to authorise the PC on screen; if the console does not show the prompt, ADB will not work.') }
        }
    } finally { $d.Dispose() }
    return $res
}

function Save-Analysis($res, [string]$basePath) {
    $res.Report | Set-Content -LiteralPath "$basePath.analysis.txt" -Encoding UTF8
    if ($res.BuildProp) { [System.IO.File]::WriteAllText("$basePath.build.prop.txt", $res.BuildProp) }
    if ($res.DefaultProp) { [System.IO.File]::WriteAllText("$basePath.default.prop.txt", $res.DefaultProp) }
}

function Invoke-Extract {
    param([string]$ImagePath, [string]$OutDir, [string[]]$Names)
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    $done = @()
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table of this image.' }
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
        foreach ($p in $L.Parts) {
            if ($Names -and ($Names -notcontains $p.Name)) { continue }
            if (-not $Names -and $p.SizeSec -lt 0) { continue }
            $f = Join-Path $OutDir "$($p.Name).img"
            if (Test-Path -LiteralPath $f) { Say "  $f already exists, skipping." Yellow; continue }
            $h = [StorioTool.Core]::CopyToNewFile($d, $p.Start, $p.Len, $f, ('Extracting {0,-8}' -f $p.Name))
            Write-Sidecar $f $h
            $done += $f
        }
    } finally { $d.Dispose() }
    return $done
}

function New-AdbSystem {
    param([string]$ImagePath, [string]$OutFile)
    if (Test-Path -LiteralPath $OutFile) { throw "$OutFile already exists" }
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table of the backup.' }
        $sys = $L.Get('system')
        if (-not $sys -or $sys.Check -ne 'ext4') { throw 'The system partition (ext4) was not found in the backup.' }
        $free = Get-FreeSpace $OutFile
        if ($free -lt ($sys.Len + 100MB)) { throw "Not enough disk space ($(Fmt $sys.Len) needed)." }
        [void][StorioTool.Core]::CopyToNewFile($d, $sys.Start, $sys.Len, $OutFile, 'Copying system   ')
        $parm = $L.ParmText
        $info = [ordered]@{ Partition = 'system'; StartSector = $sys.Start / 512; Bytes = $sys.Len; Source = $ImagePath }
    } finally { $d.Dispose() }

    $w = [StorioTool.Dev]::Open($OutFile, $true, 0, $null)
    try {
        $old = $null; $new = $null
        $changes = [StorioTool.Core]::PatchSystemImage($w, 0, [ref]$old, [ref]$new)
    } catch {
        $w.Dispose(); $w = $null
        Remove-Item -LiteralPath $OutFile -Force
        throw
    } finally { if ($w) { $w.Dispose() } }

    [System.IO.File]::WriteAllText("$OutFile.build.prop.original.txt", $old)
    [System.IO.File]::WriteAllText("$OutFile.build.prop.new.txt", $new)
    $h = [StorioTool.Core]::HashFile($OutFile, 'Computing SHA-256')
    Write-Sidecar $OutFile $h
    ($info.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) | Set-Content -LiteralPath "$OutFile.info.txt" -Encoding UTF8
    return $changes
}

function Test-SameCard {
    # Checks that the card has the same partition table and the same size as the backup
    param($CardLayout, [long]$CardSize, [string]$BackupPath)
    $b = [StorioTool.Dev]::Open($BackupPath, $false, 0, $null)
    try {
        if ($b.Length -ne $CardSize) { throw "The backup ($(Fmt $b.Length)) is not the same size as the card ($(Fmt $CardSize)). Is it the backup of THIS card?" }
        $Lb = [StorioTool.Core]::Resolve($b)
        if (-not $Lb.Verified) { throw 'The partition table of the backup is not verified.' }
        if ($Lb.ParmText -ne $CardLayout.ParmText -or $Lb.BaseSec -ne $CardLayout.BaseSec) {
            throw 'The partition table of the card and that of the backup are different.'
        }
    } finally { $b.Dispose() }
}

function Invoke-FlashPartition {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$PartFile, [string]$PartName, [string]$BackupPath, [switch]$CheckOnly)
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw 'The backup of this card is required.' }
    if (-not (Read-Sidecar $BackupPath)) { throw 'The backup has no .sha256 file (it is not verified). Make the backup with option 1.' }
    $expected = Read-Sidecar $PartFile

    $c = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        $Lc = [StorioTool.Core]::Resolve($c)
        if (-not $Lc.Verified) { throw 'Could not verify the partition table of the CARD.' }
        $p = $Lc.Get($PartName)
        if (-not $p) { throw "The card has no '$PartName' partition." }
        if ($p.SizeSec -lt 0) { throw "Partition '$PartName' has no fixed size; it is not written, for safety." }
        $cardLen = $c.Length
    } finally { $c.Dispose() }

    Test-SameCard $Lc $cardLen $BackupPath

    $f = [StorioTool.Dev]::Open($PartFile, $false, 0, $null)
    try {
        if ($f.Length -ne $p.Len) { throw "The file is $($f.Length) bytes and partition '$PartName' is $($p.Len). They do not match." }
        if ($PartName -eq 'system' -and -not [StorioTool.Core]::IsExt4At($f, 0)) { throw 'The file does not contain a valid ext4 file system.' }
        if ($PartName -eq 'boot' -and -not [StorioTool.Core]::BootMagic($f, 0)) { throw 'The file does not look like a valid boot partition.' }
        if ($CheckOnly) { return $p }
        if ($expected) {
            Say '  Checking the integrity of the file...' Cyan
            $h0 = [StorioTool.Core]::CopyHash($f, 0, $null, 0, $f.Length, 'Checking file')
            if ($h0 -ne $expected) { throw 'The file does not match its .sha256: it is corrupted.' }
        }
        $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
        try {
            $hw = [StorioTool.Core]::CopyHash($f, 0, $w, $p.Start, $p.Len, ('Writing  {0,-8}' -f $PartName))
        } finally { $w.Dispose() }
    } finally { $f.Dispose() }

    Say '  Verifying what was written...' Cyan
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $hr = [StorioTool.Core]::CopyHash($r, $p.Start, $null, 0, $p.Len, 'Verifying        ') } finally { $r.Dispose() }
    if ($hr -ne $hw) { throw 'Verification FAILED: what was read back from the card does not match what was written. Restore the backup (option 9).' }
    return $p
}

function Invoke-Restore {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$ImagePath)
    $img = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    try {
        if ($img.Length % 512 -ne 0) { throw 'The file does not have the size of a card image.' }
        if ($img.Length -gt $CardSize) { throw "The image ($(Fmt $img.Length)) is LARGER than the card ($(Fmt $CardSize)). Use a bigger card." }
        $expected = Read-Sidecar $ImagePath
        if ($expected) {
            Say '  Checking the integrity of the backup...' Cyan
            $h0 = [StorioTool.Core]::CopyHash($img, 0, $null, 0, $img.Length, 'Checking backup')
            if ($h0 -ne $expected) { throw 'The backup does NOT match its .sha256: it is corrupted. Nothing has been written.' }
        }
        $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
        try {
            $hw = [StorioTool.Core]::CopyHash($img, 0, $w, 0, $img.Length, 'Restoring        ')
        } finally { $w.Dispose() }
        $len = $img.Length
    } finally { $img.Dispose() }

    Say '  Verifying what was written...' Cyan
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $hr = [StorioTool.Core]::CopyHash($r, 0, $null, 0, $len, 'Verifying        ') } finally { $r.Dispose() }
    if ($hr -ne $hw) { throw 'Verification FAILED: the card did not end up identical to the backup.' }
    return $hr
}

function Test-CardVsImage {
    param([string]$CardPath, [long]$CardSize, [string]$ImagePath)
    $expected = Read-Sidecar $ImagePath
    if (-not $expected) { $expected = [StorioTool.Core]::HashFile($ImagePath, 'Hashing backup') }
    $len = (Get-Item -LiteralPath $ImagePath).Length
    if ($len -gt $CardSize) { return $false }
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try { $h = [StorioTool.Core]::CopyHash($r, 0, $null, 0, $len, 'Reading card     ') } finally { $r.Dispose() }
    return ($h -eq $expected)
}

function Invoke-FixPersist {
    param([string]$CardPath, [long]$CardSize, [string[]]$Volumes, [string]$BackupPath, [switch]$CheckOnly)
    if (-not (Read-Sidecar $BackupPath)) { throw 'A verified backup of this card is required (option 1).' }
    $c = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    $targets = @()
    try {
        $Lc = [StorioTool.Core]::Resolve($c)
        if (-not $Lc.Verified) { throw 'Could not verify the partition table of the CARD.' }
        $cardLen = $c.Length
        foreach ($pn in @('data', 'userdata')) {
            $p = $Lc.Get($pn)
            if (-not $p -or $p.Check -ne 'ext4') { continue }
            $pp = [StorioTool.Core]::ReadPersist($c, $p.Start)
            if ([StorioTool.Core]::PersistNeedsFix($pp)) { $targets += $p }
        }
    } finally { $c.Dispose() }
    Test-SameCard $Lc $cardLen $BackupPath
    if ($CheckOnly -or $targets.Count -eq 0) { return ,$targets }
    $w = [StorioTool.Dev]::Open($CardPath, $true, $CardSize, $Volumes)
    $changes = ''
    try {
        foreach ($p in $targets) { $changes += [StorioTool.Core]::PatchPersist($w, $p.Start) }
    } finally { $w.Dispose() }
    $r = [StorioTool.Dev]::Open($CardPath, $false, $CardSize, $null)
    try {
        foreach ($p in $targets) {
            $left = [StorioTool.Core]::PersistNeedsFix([StorioTool.Core]::ReadPersist($r, $p.Start))
            if ($left) { throw "Verification failed on '$($p.Name)': $left" }
        }
    } finally { $r.Dispose() }
    return $changes
}

function Get-Contents {
    param([string]$ImagePath, [string]$OutFile)
    $d = [StorioTool.Dev]::Open($ImagePath, $false, 0, $null)
    $lines = New-Object System.Collections.Generic.List[string]
    $apks = New-Object System.Collections.Generic.List[string]
    try {
        $L = [StorioTool.Core]::Resolve($d)
        if (-not $L.Verified) { throw 'Could not verify the partition table.' }
        foreach ($pn in @('system', 'data', 'userdata')) {
            $p = $L.Get($pn)
            if (-not $p -or $p.Check -ne 'ext4') { continue }
            $fs = New-Object StorioTool.Ext4($d, $p.Start)
            $root = if ($pn -eq 'system') { '/app' } else { '/' }
            $t = $fs.Tree($root, 50000)
            $lines.Add("===== $pn ($root) - $($t.Count) entries =====")
            $total = [long]0
            foreach ($entry in $t) {
                $parts = $entry.Split("`t", 2)
                $sz = 0L; [void][long]::TryParse($parts[0], [ref]$sz); $total += $sz
                $lines.Add(('{0,12}  {1}' -f $parts[0], $parts[1]))
                if ($parts[1] -match '\.(apk|obb|zip|dat|pak|bin|vt\w*)$' -and $sz -gt 1MB) { $apks.Add(('{0,-6} {1,10}  {2}' -f $pn, (Fmt $sz), $parts[1])) }
            }
            $lines.Add("  Total files: $(Fmt $total)")
            $lines.Add('')
        }
    } finally { $d.Dispose() }
    $head = New-Object System.Collections.Generic.List[string]
    $head.Add("Contents of $ImagePath")
    $head.Add('')
    $head.Add('== Large files (apk, obb, data packages > 1 MB) ==')
    foreach ($a in $apks) { $head.Add("  $a") }
    $head.Add('')
    ($head + $lines) | Set-Content -LiteralPath $OutFile -Encoding UTF8
    return $apks
}

function Find-Chdman {
    $cands = @()
    $here = Split-Path -Parent $PSCommandPath
    if ($here) { $cands += (Join-Path $here 'chdman.exe') }
    $cmd = Get-Command chdman -ErrorAction SilentlyContinue
    if ($cmd) { $cands += $cmd.Source }
    $cands += @('C:\mame\chdman.exe', "$env:ProgramFiles\MAME\chdman.exe", "$env:USERPROFILE\Downloads\mame\chdman.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# ------------------------------------------------------------------ menu

function Show-Header {
    Clear-Host
    Say '  ==============================================================' DarkCyan
    Say "   STORIO TV / INNOTV  -  Card tool   v$Script:ToolVersion" White
    Say '  ==============================================================' DarkCyan
    Say "   Working folder: $Script:WorkDir" DarkGray
    $last = Get-LatestBackup
    if ($last) { Say "   Latest backup: $($last.Name)" DarkGray } else { Say '   There is no backup yet. Start with option 1.' Yellow }
    Say ''
}

function Menu-Backup {
    Say '  FULL BACKUP OF THE CARD' White
    Say '  If Windows asks you to "format the disk", ALWAYS click Cancel.' Yellow
    $card = Select-Card; if (-not $card) { return }
    $name = 'backup_{0:yyyyMMdd_HHmm}.img' -f (Get-Date)
    $out = Join-Path $Script:WorkDir $name
    Say "  It will be saved to: $out" Cyan
    Say "  Size: $(Fmt $card.Size). It will take several minutes (read + verification)." Cyan
    if (-not (Confirm-Yes 'Start?')) { return }
    $h = Invoke-Backup -CardPath $card.Path -CardSize $card.Size -OutFile $out
    Say "  Backup completed and verified." Green
    Say "  SHA-256: $h" DarkGray
    Say '  Analysing the backup...' Cyan
    $res = Get-Analysis -Path $out
    Save-Analysis $res $out
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $out.analysis.txt" Green
    Say '  Also copy the backup somewhere else (external drive, cloud) just in case.' Yellow
}

function Menu-Analyze([bool]$fromCard) {
    if ($fromCard) {
        $card = Select-Card; if (-not $card) { return }
        $res = Get-Analysis -Path $card.Path -Length $card.Size
        $base = Join-Path $Script:WorkDir ('card_{0:yyyyMMdd_HHmm}' -f (Get-Date))
    } else {
        $img = Select-Backup 'Choose the backup (.img) to analyse'; if (-not $img) { return }
        $res = Get-Analysis -Path $img
        $base = $img
    }
    Save-Analysis $res $base
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $base.analysis.txt" Green
    if ($res.BuildProp) { Say "  Full build.prop in $base.build.prop.txt" Green }
}

function Menu-Verify {
    $img = Select-Backup 'Choose the backup (.img) to compare with'; if (-not $img) { return }
    $card = Select-Card; if (-not $card) { return }
    if (Test-CardVsImage -CardPath $card.Path -CardSize $card.Size -ImagePath $img) {
        Say '  The card is IDENTICAL to the backup.' Green
    } else {
        Say '  The card is DIFFERENT from the backup (normal if the console has been used since the backup, or if you have written something).' Yellow
    }
}

function Menu-Extract {
    $img = Select-Backup 'Choose the backup (.img)'; if (-not $img) { return }
    $leaf = ((Split-Path -Leaf $img) -replace '\.img$', '') + '_partitions'
    $dir = Join-Path (Split-Path -Parent $img) $leaf
    Say '  1) Only boot and system (recommended)   2) All fixed-size partitions'
    $o = Read-Host '  Option'
    $names = if ($o -eq '2') { $null } else { @('boot', 'system') }
    $files = Invoke-Extract -ImagePath $img -OutDir $dir -Names $names
    Say "  Extracted $($files.Count) partitions to $dir" Green
}

function Menu-Adb {
    Say '  CREATE SYSTEM WITH ADB ENABLED' White
    Say '  A NEW file is created from the backup; the backup is not modified.' DarkGray
    $img = Select-Backup 'Choose the backup (.img)'; if (-not $img) { return }
    $out = Join-Path (Split-Path -Parent $img) ('system_adb_{0:yyyyMMdd_HHmm}.img' -f (Get-Date))
    $changes = New-AdbSystem -ImagePath $img -OutFile $out
    if (-not $changes) {
        Say '  build.prop already had ADB enabled; nothing needed to be changed.' Yellow
        return
    }
    Say '  Changes in build.prop:' Cyan
    Say $changes
    Say "  Created and verified: $out" Green
    Say '  To use it, write this file to the card with option 7 (system partition).' Cyan
}

function Menu-Flash {
    Say '  WRITE A PARTITION TO THE CARD' White
    $file = Select-File 'Choose the partition image to write (e.g. system_adb_....img)' $Script:WorkDir
    if (-not $file) { return }
    $guess = if ((Split-Path -Leaf $file) -match '^(system|boot)') { $Matches[1] } else { '' }
    $name = Read-Host "  Which partition should it be written to? (system/boot) [$guess]"
    if (-not $name) { $name = $guess }
    if (@('system', 'boot') -notcontains $name) { Say '  Only system or boot can be written.' Red; return }
    Say '  Now choose the BACKUP of this same card (to check that it is the right card).' Cyan
    $bk = Select-Backup 'Choose the backup of the card'; if (-not $bk) { return }
    $card = Select-Card; if (-not $card) { return }
    $p = Invoke-FlashPartition -CardPath $card.Path -CardSize $card.Size -Volumes @() -PartFile $file -PartName $name -BackupPath $bk -CheckOnly
    Say "  Checks passed: card = backup, '$name' at sector 0x$('{0:X}' -f ($p.Start/512)), $(Fmt $p.Len)." Green
    if (-not (Confirm-Danger "partition '$name' of disk $($card.Number) ($($card.Name)) is about to be overwritten")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    [void](Invoke-FlashPartition -CardPath $card.Path -CardSize $card.Size -Volumes $vols -PartFile $file -PartName $name -BackupPath $bk)
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say "  Partition '$name' written and verified." Green
    Say '  Put the card back in the console, switch it on and connect it via USB.' Cyan
}

function Menu-Restore {
    Say '  RESTORE A FULL BACKUP' White
    $img = Select-Backup 'Choose the backup (.img) to restore'; if (-not $img) { return }
    if (-not (Read-Sidecar $img)) {
        Say '  This file has no .sha256: it cannot be checked for integrity.' Yellow
        if (-not (Confirm-Yes 'Continue anyway?')) { return }
    }
    $res = Get-Analysis -Path $img
    if (-not $res.Layout.Verified) {
        Say '  Warning: this file does not look like a Storio TV card.' Yellow
        if (-not (Confirm-Yes 'Continue anyway?')) { return }
    }
    $card = Select-Card; if (-not $card) { return }
    $imgLen = (Get-Item -LiteralPath $img).Length
    if ($imgLen -gt $card.Size) { Say "  The card ($(Fmt $card.Size)) is smaller than the backup ($(Fmt $imgLen)). Use a bigger card." Red; return }
    if ($imgLen -lt $card.Size) { Say "  The card is larger than the backup; the extra space will not be used (this is fine)." DarkGray }
    if (-not (Confirm-Danger "ALL of disk $($card.Number) ($($card.Name), $(Fmt $card.Size)) is about to be ERASED and replaced with the backup")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    [void](Invoke-Restore -CardPath $card.Path -CardSize $card.Size -Volumes $vols -ImagePath $img)
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say '  Backup restored and verified.' Green
}

function Menu-FixPersist {
    Say '  FIX THE USB SETTING SAVED ON THE CARD' White
    Say '  Android saves a USB setting in /data/property that takes precedence over build.prop.' DarkGray
    Say '  If it says "mtp" (without adb), ADB will not start even if you have written the system with ADB.' DarkGray
    $bk = Select-Backup 'Choose the backup of this card'; if (-not $bk) { return }
    $card = Select-Card; if (-not $card) { return }
    $t = Invoke-FixPersist -CardPath $card.Path -CardSize $card.Size -Volumes @() -BackupPath $bk -CheckOnly
    if ($t.Count -eq 0) { Say '  There is no saved setting that disables ADB. Nothing needs to be done.' Green; return }
    Say "  The setting needs to be fixed in: $(($t | ForEach-Object { $_.Name }) -join ', ')" Cyan
    if (-not (Confirm-Danger "a small file on the card in disk $($card.Number) ($($card.Name)) is about to be modified")) { Say '  Cancelled.'; return }
    $vols = Get-CardVolumes $card.Number
    $ch = Invoke-FixPersist -CardPath $card.Path -CardSize $card.Size -Volumes $vols -BackupPath $bk
    try { Update-Disk -Number $card.Number -ErrorAction SilentlyContinue } catch { }
    Say $ch
    Say '  Setting fixed and verified.' Green
}

function Menu-Chd {
    Say '  CONVERT A .CHD FILE TO .IMG AND ANALYSE IT' White
    $chd = Select-File 'Choose the .chd file' $Script:WorkDir
    if (-not $chd) { return }
    $chdman = Find-Chdman
    if (-not $chdman) {
        Say '  chdman.exe not found. It is included with MAME (https://www.mamedev.org/release.html).' Yellow
        Say '  Download MAME for Windows, unzip it and copy chdman.exe to the folder of this tool.' Yellow
        return
    }
    Say '  CHD information:' Cyan
    & $chdman info -i $chd | ForEach-Object { Say "    $_" }
    $out = Join-Path $Script:WorkDir (([System.IO.Path]::GetFileNameWithoutExtension($chd)) + '_chd.img')
    if (Test-Path -LiteralPath $out) { Say "  $out already exists; analysing that one." Yellow }
    else {
        if ((Get-FreeSpace $out) -lt 9GB) { throw 'About 9 GB of free space is needed to decompress the CHD.' }
        if (-not (Confirm-Yes "Decompress to $out ?")) { return }
        & $chdman extracthd -i $chd -o $out
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw 'chdman could not decompress the file (is it not a hard disk/card image?).' }
        $h = [StorioTool.Core]::HashFile($out, 'Computing SHA-256')
        Write-Sidecar $out $h
    }
    $res = Get-Analysis -Path $out
    Save-Analysis $res $out
    $res.Report | ForEach-Object { Say "  $_" }
    Say "`n  Report saved to $out.analysis.txt" Green
}

function Menu-Contents {
    Say '  VIEW APPS AND GAMES INSIDE AN IMAGE' White
    $img = Select-File 'Choose the image (.img) to inspect' $Script:WorkDir
    if (-not $img) { return }
    $out = "$img.contents.txt"
    $apks = Get-Contents -ImagePath $img -OutFile $out
    Say '  Large files found:' Cyan
    foreach ($a in $apks) { Say "    $a" }
    Say "`n  Full listing in $out" Green
}

function Start-Menu {
    if (-not ($IsLinux -or $IsMacOS)) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Say '  This must be run as administrator. Reopening...' Yellow
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            return
        }
    }
    if (-not (Test-Path -LiteralPath $Script:WorkDir)) { New-Item -ItemType Directory -Path $Script:WorkDir | Out-Null }
    try { Start-Transcript -Path (Join-Path $Script:WorkDir 'log.txt') -Append | Out-Null } catch { }
    while ($true) {
        Show-Header
        Say '   1) Make a full backup of the card (with verification)'
        Say '   2) Analyse a backup (partitions, firmware version, ADB)'
        Say '   3) Analyse the card directly (read-only)'
        Say '   4) Check whether the card is identical to a backup'
        Say '   5) Extract partitions from a backup'
        Say '   6) Create a system partition with ADB enabled'
        Say '   7) Write a partition to the card (system or boot)' Yellow
        Say '   8) Fix the USB setting saved on the card (data)' Yellow
        Say '   9) Restore a full backup to the card' Yellow
        Say '  10) Convert a .chd file to .img and analyse it'
        Say '  11) View apps and games inside an image'
        Say '  12) Open the working folder'
        Say '   0) Exit'
        Say ''
        $o = Read-Host '  Choose an option'
        Say ''
        if ($o -eq '0') { try { Stop-Transcript | Out-Null } catch { }; return }
        if ($o -eq '12') { Start-Process explorer.exe $Script:WorkDir; continue }
        if ('1','2','3','4','5','6','7','8','9','10','11' -notcontains $o) { continue }
        try {
            switch ($o) {
                '1' { Menu-Backup }
                '2' { Menu-Analyze $false }
                '3' { Menu-Analyze $true }
                '4' { Menu-Verify }
                '5' { Menu-Extract }
                '6' { Menu-Adb }
                '7' { Menu-Flash }
                '8' { Menu-FixPersist }
                '9' { Menu-Restore }
                '10' { Menu-Chd }
                '11' { Menu-Contents }
            }
        } catch {
            Say ''
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            Say "  ERROR: $($e.Message)" Red
            Say '  The operation was not completed.' Red
        }
        Pause-Tool
    }
}

if (-not $NoMenu) { Start-Menu }
