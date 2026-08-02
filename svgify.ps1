param(
    [Parameter(Mandatory = $true)][string]$InputFont,
    [Parameter(Mandatory = $true)][string]$OutputFont,
    [int]$Ppem = 0
)

# Adds an OT-SVG ('SVG ') table to a CBDT/CBLC color-bitmap font.
#
# Why this exists
# ---------------
# AppleColorEmoji-Windows.ttf carries its artwork only in CBDT/CBLC (PNG bitmap
# strikes). Gecko does not rasterize CBDT on Windows: DirectWrite hands an app
# the raw PNG bytes via IDWriteFontFace4::GetGlyphImageData and expects the app
# to blit them, which Blink/Skia implements and Gecko does not. Gecko therefore
# falls back to the font's 'glyf' outlines, and in a bitmap-only font those are
# zero-area placeholders, so every emoji comes out blank in Firefox/LibreWolf.
#
# Gecko *does* implement OT-SVG on every platform, and an OT-SVG glyph document
# may embed a raster image. So this script re-wraps the existing PNGs as <image>
# elements with data: URIs in an 'SVG ' table and splices that table into the
# font alongside the untouched CBDT. Each engine then picks the format it can
# actually render:
#
#     Gecko          -> 'SVG '
#     Blink / Skia   -> CBDT (it does not implement OT-SVG at all)
#     Direct2D       -> either; both are supported natively
#
# The splice happens at the sfnt binary level, so every existing table -
# including Apple's 'morx', 'bgcl', 'feat' and 'trak' - is copied byte for byte.
#
# The heavy lifting is in C# rather than PowerShell: the checksum pass alone
# walks ~86 million 32-bit words, which takes minutes in the PowerShell
# interpreter and under a second in compiled code. Add-Type ships with Windows,
# so this still needs nothing installed.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$svgifySource = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

public static class SvgifyCore
{
    const uint MAGIC = 0xB1B0AFBA;

    static ushort U16(byte[] d, int o) { return (ushort)((d[o] << 8) | d[o + 1]); }

    static uint U32(byte[] d, int o)
    {
        return ((uint)d[o] << 24) | ((uint)d[o + 1] << 16)
             | ((uint)d[o + 2] << 8) | (uint)d[o + 3];
    }

    // sfnt checksum: sum of big-endian uint32 words, zero padded to 4 bytes.
    static uint Checksum(byte[] d, int off, int len)
    {
        uint sum = 0;
        int whole = len & ~3;
        for (int i = 0; i < whole; i += 4) sum += U32(d, off + i);
        if (whole != len)
        {
            uint tail = 0;
            for (int k = 0; k < 4; k++)
            {
                int idx = whole + k;
                tail = (tail << 8) | (idx < len ? (uint)d[off + idx] : 0u);
            }
            sum += tail;
        }
        return sum;
    }

    // Compact decimal; SVG parsers dislike exponents and long tails.
    static string Num(double v)
    {
        double r = Math.Round(v, 2, MidpointRounding.ToEven);
        if (r == Math.Floor(r))
            return ((long)r).ToString(CultureInfo.InvariantCulture);
        return r.ToString("0.##", CultureInfo.InvariantCulture);
    }

    class Art
    {
        public int Offset, Length, Width, Height, Ppem, BearingX, BearingY;
    }

    class Entry
    {
        public string Tag;
        public byte[] Buf;          // when set, the payload lives here
        public int Off, Len;        // otherwise it is a slice of the input
        public int Size { get { return Buf != null ? Buf.Length : Len; } }
    }

    // indexFormat 1/3 with imageFormat 17/18 is what apple-emoji-ttf emits.
    // Anything else throws rather than being skipped, so a future font
    // revision cannot quietly yield a partial SVG table.
    static Dictionary<int, Art> ExtractStrike(byte[] d, int cbdt, int ista,
                                              int numIst, int ppem)
    {
        var found = new Dictionary<int, Art>();
        for (int k = 0; k < numIst; k++)
        {
            int a = ista + k * 8;
            int firstG = U16(d, a);
            int lastG = U16(d, a + 2);
            int h = ista + (int)U32(d, a + 4);
            int idxFmt = U16(d, h);
            int imgFmt = U16(d, h + 2);
            int imgOff = (int)U32(d, h + 4);
            int n = lastG - firstG + 1;

            if (idxFmt != 1 && idxFmt != 3)
                throw new Exception("unsupported CBLC indexFormat " + idxFmt);
            if (imgFmt != 17 && imgFmt != 18)
                throw new Exception("unsupported CBDT imageFormat " + imgFmt);

            // format 17 = SmallGlyphMetrics (5 bytes) + uint32 len + PNG
            // format 18 = BigGlyphMetrics  (8 bytes) + uint32 len + PNG
            int metricsSize = (imgFmt == 17) ? 5 : 8;

            for (int i = 0; i < n; i++)
            {
                int cur, next;
                if (idxFmt == 1)
                {
                    cur = (int)U32(d, h + 8 + i * 4);
                    next = (int)U32(d, h + 8 + (i + 1) * 4);
                }
                else
                {
                    cur = U16(d, h + 8 + i * 2);
                    next = U16(d, h + 8 + (i + 1) * 2);
                }
                if (next - cur <= 0) continue;

                int p = cbdt + imgOff + cur;
                int height = d[p];
                int width = d[p + 1];
                int bearingX = (sbyte)d[p + 2];
                int bearingY = (sbyte)d[p + 3];
                p += metricsSize;
                int dataLen = (int)U32(d, p);
                p += 4;

                if (!(d[p] == 0x89 && d[p + 1] == 0x50 && d[p + 2] == 0x4E
                      && d[p + 3] == 0x47))
                    throw new Exception("CBDT payload is not a PNG at glyph "
                                        + (firstG + i));

                var art = new Art();
                art.Offset = p; art.Length = dataLen;
                art.Width = width; art.Height = height;
                art.BearingX = bearingX; art.BearingY = bearingY;
                art.Ppem = ppem;
                found[firstG + i] = art;
            }
        }
        return found;
    }

    public static List<string> Build(string inPath, string outPath,
                                     int preferredPpem)
    {
        var log = new List<string>();
        byte[] d = File.ReadAllBytes(inPath);

        if (!(d[0] == 0 && d[1] == 1 && d[2] == 0 && d[3] == 0))
            throw new Exception("not a TrueType file");

        int numTables = U16(d, 4);
        var order = new List<string>();
        var tOff = new Dictionary<string, int>();
        var tLen = new Dictionary<string, int>();
        for (int i = 0; i < numTables; i++)
        {
            int o = 12 + i * 16;
            string tag = Encoding.ASCII.GetString(d, o, 4);
            order.Add(tag);
            tOff[tag] = (int)U32(d, o + 8);
            tLen[tag] = (int)U32(d, o + 12);
        }
        foreach (string need in new string[] { "CBDT", "CBLC", "head", "maxp" })
            if (!tOff.ContainsKey(need))
                throw new Exception("input is missing a '" + need + "' table");
        if (tOff.ContainsKey("SVG "))
            throw new Exception("input already has an 'SVG ' table; refusing");

        log.Add(string.Format("[INFO] {0}: {1:n0} bytes, {2} tables",
                              inPath, d.LongLength, numTables));

        int upm = U16(d, tOff["head"] + 18);
        if (upm < 16 || upm > 16384)
            throw new Exception("unitsPerEm " + upm + " is out of range; "
                                + "Gecko would ignore the SVG table");

        int cblc = tOff["CBLC"];
        int cbdt = tOff["CBDT"];
        if (U16(d, cblc) != 3)
            throw new Exception("unexpected CBLC version " + U16(d, cblc));

        int numSizes = (int)U32(d, cblc + 4);
        var ppems = new List<int>();
        var istaOf = new Dictionary<int, int>();
        var nistOf = new Dictionary<int, int>();
        for (int s = 0; s < numSizes; s++)
        {
            int b = cblc + 8 + s * 48;
            int ppem = d[b + 44];
            ppems.Add(ppem);
            istaOf[ppem] = cblc + (int)U32(d, b);
            nistOf[ppem] = (int)U32(d, b + 8);
        }

        int chosen = preferredPpem;
        if (chosen == 0)
        {
            foreach (int p in ppems) if (p > chosen) chosen = p;
        }
        else if (!istaOf.ContainsKey(chosen))
        {
            ppems.Sort();
            throw new Exception("no strike at " + chosen + " ppem; available: "
                                + string.Join(", ", ppems.ConvertAll(
                                    x => x.ToString()).ToArray()));
        }
        log.Add(string.Format(
            "[INFO] unitsPerEm={0}, strike @ {1}ppem, {2} index subtables",
            upm, chosen, nistOf[chosen]));

        // Artwork comes from the preferred strike, with any glyph it lacks
        // filled in from the next largest strike that has one. Strikes are not
        // individually complete: in the current release 20 ligature-only
        // glyphs are absent at 96 ppem but present everywhere else. Falling
        // back keeps the SVG table covering exactly CBDT's glyph set, so
        // Firefox never shows a blank where Blink shows art.
        var searchOrder = new List<int>();
        searchOrder.Add(chosen);
        var rest = new List<int>(ppems);
        rest.Sort();
        rest.Reverse();
        foreach (int p in rest) if (p != chosen) searchOrder.Add(p);

        var glyphs = new Dictionary<int, Art>();
        foreach (int p in searchOrder)
        {
            var found = ExtractStrike(d, cbdt, istaOf[p], nistOf[p], p);
            int added = 0;
            foreach (var kv in found)
                if (!glyphs.ContainsKey(kv.Key))
                {
                    glyphs[kv.Key] = kv.Value;
                    added++;
                }
            if (added > 0 && p != chosen)
                log.Add(string.Format(
                    "[INFO] {0} glyph(s) absent at {1}ppem taken from the "
                    + "{2}ppem strike", added, chosen, p));
        }
        if (glyphs.Count == 0)
            throw new Exception("no bitmaps extracted; refusing to write an "
                                + "empty SVG table");
        if (glyphs.Count > 0xFFFF)
            throw new Exception(glyphs.Count + " documents exceeds the uint16 "
                                + "numEntries limit of the SVG document list");

        var gids = new List<int>(glyphs.Keys);
        gids.Sort();
        long artBytes = 0;
        foreach (int g in gids) artBytes += glyphs[g].Length;
        log.Add(string.Format("[OK]   extracted {0:n0} PNGs ({1:n0} bytes of "
                              + "artwork)", gids.Count, artBytes));

        // SVG table layout per the OpenType spec:
        //   header   : uint16 version=0, Offset32 docListOffset, uint32 reserved
        //   doc list : uint16 numEntries, then per entry uint16 startGlyphID,
        //              uint16 endGlyphID, Offset32 docOffset (from list start),
        //              uint32 docLength
        // Records must be sorted by startGlyphID and must not overlap; one
        // glyph per record makes that trivially true.
        int recordsSize = 2 + gids.Count * 12;
        var docs = new MemoryStream((int)(artBytes * 4 / 3) + gids.Count * 320);
        var records = new MemoryStream(recordsSize);
        WriteU16(records, (ushort)gids.Count);
        int cursor = recordsSize;

        var sb = new StringBuilder(1 << 16);
        foreach (int gid in gids)
        {
            Art a = glyphs[gid];
            double scale = (double)upm / a.Ppem;
            sb.Length = 0;
            sb.Append("<svg xmlns=\"http://www.w3.org/2000/svg\"");
            sb.Append(" xmlns:xlink=\"http://www.w3.org/1999/xlink\">");
            sb.Append("<image id=\"glyph");
            sb.Append(gid.ToString(CultureInfo.InvariantCulture));
            sb.Append("\" x=\"").Append(Num(a.BearingX * scale));
            sb.Append("\" y=\"").Append(Num(-a.BearingY * scale));
            sb.Append("\" width=\"").Append(Num(a.Width * scale));
            sb.Append("\" height=\"").Append(Num(a.Height * scale));
            sb.Append("\" xlink:href=\"data:image/png;base64,");
            sb.Append(Convert.ToBase64String(d, a.Offset, a.Length));
            sb.Append("\"/></svg>");

            byte[] doc = Encoding.UTF8.GetBytes(sb.ToString());
            WriteU16(records, (ushort)gid);
            WriteU16(records, (ushort)gid);
            WriteU32(records, (uint)cursor);
            WriteU32(records, (uint)doc.Length);
            docs.Write(doc, 0, doc.Length);
            cursor += doc.Length;
        }

        var svg = new MemoryStream(10 + cursor);
        WriteU16(svg, 0);           // version
        WriteU32(svg, 10);          // svgDocumentListOffset
        WriteU32(svg, 0);           // reserved
        records.WriteTo(svg);
        docs.WriteTo(svg);
        byte[] svgTable = svg.ToArray();
        docs.Dispose(); records.Dispose(); svg.Dispose();
        log.Add(string.Format("[OK]   SVG table {0:n0} bytes",
                              svgTable.Length));

        // Table offsets are uint32 and this writer tracks them in int, so a
        // pathologically large input would silently wrap and emit a corrupt
        // font. Fail loudly instead. (The real font is ~345 MB.)
        long projected = d.LongLength + svgTable.LongLength + 16
                       + 16L * (numTables + 1);
        if (projected > int.MaxValue)
            throw new Exception("output would be " + projected + " bytes, "
                + "beyond the 2 GB this writer can address");

        var entries = new List<Entry>();
        foreach (string tag in order)
        {
            var e = new Entry();
            e.Tag = tag;
            if (tag == "head")
            {
                // checkSumAdjustment must be zero while checksums are computed
                var head = new byte[tLen[tag]];
                Array.Copy(d, tOff[tag], head, 0, head.Length);
                head[8] = head[9] = head[10] = head[11] = 0;
                e.Buf = head;
            }
            else { e.Off = tOff[tag]; e.Len = tLen[tag]; }
            entries.Add(e);
        }
        var svgEntry = new Entry();
        svgEntry.Tag = "SVG ";
        svgEntry.Buf = svgTable;
        entries.Add(svgEntry);
        entries.Sort(delegate (Entry x, Entry y) {
            return string.CompareOrdinal(x.Tag, y.Tag);
        });

        int count = entries.Count;
        int entrySelector = 0;
        while ((1 << (entrySelector + 1)) <= count) entrySelector++;
        int searchRange = (1 << entrySelector) * 16;
        int rangeShift = count * 16 - searchRange;

        var dir = new MemoryStream(12 + count * 16);
        WriteU32(dir, 0x00010000);
        WriteU16(dir, (ushort)count);
        WriteU16(dir, (ushort)searchRange);
        WriteU16(dir, (ushort)entrySelector);
        WriteU16(dir, (ushort)rangeShift);

        int headPos = -1;
        int pos = 12 + count * 16;
        foreach (Entry e in entries)
        {
            if (e.Tag == "head") headPos = pos;
            uint csum = (e.Buf != null)
                ? Checksum(e.Buf, 0, e.Buf.Length)
                : Checksum(d, e.Off, e.Len);
            dir.Write(Encoding.ASCII.GetBytes(e.Tag), 0, 4);
            WriteU32(dir, csum);
            WriteU32(dir, (uint)pos);
            WriteU32(dir, (uint)e.Size);
            pos += e.Size + ((4 - (e.Size & 3)) & 3);
        }
        byte[] dirBytes = dir.ToArray();
        dir.Dispose();

        // Every chunk written is a multiple of 4 bytes, so accumulating the
        // whole-file checksum chunk by chunk is exact.
        uint total = Checksum(dirBytes, 0, dirBytes.Length);
        var pad = new byte[4];
        using (var fs = new FileStream(outPath, FileMode.Create,
                                       FileAccess.ReadWrite, FileShare.None,
                                       1 << 20))
        {
            fs.Write(dirBytes, 0, dirBytes.Length);
            foreach (Entry e in entries)
            {
                int padLen = (4 - (e.Size & 3)) & 3;
                if (e.Buf != null)
                {
                    fs.Write(e.Buf, 0, e.Buf.Length);
                    total += Checksum(e.Buf, 0, e.Buf.Length);
                }
                else
                {
                    fs.Write(d, e.Off, e.Len);
                    total += Checksum(d, e.Off, e.Len);
                }
                if (padLen > 0) fs.Write(pad, 0, padLen);
            }
            uint adjustment = MAGIC - total;
            fs.Position = headPos + 8;
            fs.WriteByte((byte)(adjustment >> 24));
            fs.WriteByte((byte)(adjustment >> 16));
            fs.WriteByte((byte)(adjustment >> 8));
            fs.WriteByte((byte)adjustment);
            log.Add(string.Format(
                "[OK]   wrote {0} ({1:n0} bytes, {2} tables, "
                + "checkSumAdjustment=0x{3:X8})",
                outPath, pos, count, adjustment));
        }
        return log;
    }

    static void WriteU16(Stream s, ushort v)
    {
        s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
    }

    static void WriteU32(Stream s, uint v)
    {
        s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16));
        s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
    }
}
'@

if (-not ('SvgifyCore' -as [type])) {
    Add-Type -TypeDefinition $svgifySource -Language CSharp
}

$resolvedIn = (Resolve-Path -LiteralPath $InputFont).ProviderPath
$outDir = Split-Path -Parent $OutputFont
if ([string]::IsNullOrEmpty($outDir)) { $outDir = "." }
$resolvedOut = Join-Path (Resolve-Path -LiteralPath $outDir).ProviderPath (Split-Path -Leaf $OutputFont)

foreach ($line in [SvgifyCore]::Build($resolvedIn, $resolvedOut, $Ppem)) {
    Write-Output $line
}
