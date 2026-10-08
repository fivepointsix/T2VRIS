# Create the VR asset ZIP from your own Thief II installation.
# Save this script in the game folder, or pass -InstallPath explicitly.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InstallPath,
    [Parameter(Position = 1)]
    [string]$OutputPath,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$temporary = $null
try {
    # Windows PowerShell 5.1 sets PSScriptRoot after parameter defaults run.
    if (-not $InstallPath) { $InstallPath = $PSScriptRoot }
    $root = (Get-Item -LiteralPath $InstallPath).FullName.TrimEnd('\')
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    $files = New-Object 'System.Collections.Generic.List[object]'
    $added = @{}
    function Add-Payload([string]$source, [string]$name) {
        $fullPath = [IO.Path]::GetFullPath($source)
        if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Asset path is outside the Thief II folder: $name"
        }
        $item = Get-Item -LiteralPath $fullPath
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a regular game file: $name" }
        $name = $name.Replace('\', '/')
        if (-not $added.ContainsKey($name)) {
            $files.Add([pscustomobject]@{ Source = $fullPath; Path = $name; Size = [long]$item.Length })
            $added[$name] = $true
        }
    }
    $required = @('MISS1.MIS', 'DARK.GAM', 'motiondb.bin',
        'RES/fam.crf', 'RES/obj.crf', 'RES/mesh.crf', 'RES/motions.crf',
        'RES/pal.crf', 'RES/snd.crf', 'RES/song.crf')
    $missing = @()
    foreach ($name in $required) {
        $source = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -and $name.StartsWith('RES/')) {
            $source = Join-Path $root ($name.Substring(4))
        }
        if (Test-Path -LiteralPath $source -PathType Leaf) { Add-Payload $source $name }
        else { $missing += $name }
    }
    if ($missing.Count) { throw ("Missing required game files: " + ($missing -join ', ') + ". Run this script in your Thief II installation folder.") }
    $camMod = Join-Path $root 'cam_mod.ini'
    $modDirs = @('')
    if (Test-Path -LiteralPath $camMod -PathType Leaf) {
        Add-Payload $camMod 'cam_mod.ini'
        foreach ($raw in Get-Content -LiteralPath $camMod) {
            $line = ($raw -replace ';.*$', '').Trim()
            if ($line -match '^(uber_mod_path|mod_path)\s+(.+)$') {
                foreach ($part in $Matches[2].Split('+')) {
                    $dir = $part.Trim().Replace('\', '/').TrimEnd('/') -replace '^\./', ''
                    if ($dir) { $modDirs += $dir }
                }
            }
        }
    }
    foreach ($dir in ($modDirs | Select-Object -Unique)) {
        $modRoot = [IO.Path]::GetFullPath((Join-Path $root $dir))
        if ($modRoot -ne $root -and -not $modRoot.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Skipping sky mod outside the game folder: $dir"
            continue
        }
        foreach ($dml in @('miss_all.dml', 'miss1.mis.dml')) {
            $source = Join-Path $modRoot $dml
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $name = if ($dir) { $dir + '/' + $dml } else { $dml }
                Add-Payload $source $name
            }
        }
        $skyDir = Join-Path $modRoot 'fam/skyhw'
        if (Test-Path -LiteralPath $skyDir -PathType Container) {
            foreach ($image in Get-ChildItem -LiteralPath $skyDir -Recurse -File) {
                if ($image.Extension -in @('.dds', '.tga', '.pcx')) {
                    Add-Payload $image.FullName ($image.FullName.Substring($rootPrefix.Length).Replace('\', '/'))
                }
            }
        }
    }
    $total = [long](($files | Measure-Object Size -Sum).Sum)
    if ($files.Count -ge 4096 -or $total + 4194304 -gt 2147483648) { throw 'This first-mission package exceeds the 2 GiB limit.' }
    $manifest = [ordered]@{
        format = 'thief2-vr-assets'
        version = 1
        mission = 'MISS1.MIS'
        createdUtc = [DateTime]::UtcNow.ToString('o')
        files = @($files | ForEach-Object { [ordered]@{ path = $_.Path; size = $_.Size } })
    } | ConvertTo-Json -Depth 5
    $output = $OutputPath
    if (-not $output) { $output = Join-Path $root 'Thief2-VR-assets.zip' }
    $output = [IO.Path]::GetFullPath($output)
    if ([IO.Path]::GetExtension($output) -ne '.zip') { throw 'The output filename must end in .zip.' }
    if (Test-Path -LiteralPath $output) { throw "ZIP already exists: $output. Move it aside or choose a different output filename." }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($output)) -PathType Container)) { throw 'The output folder does not exist.' }
    $temporary = $output + '.partial-' + [Guid]::NewGuid().ToString('N')

    # Windows PowerShell's built-in ZipArchive still uses DEFLATE for
    # NoCompression. Write real method-0 entries so browsers can stream them.
    if (-not ('Thief2VrZip' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class Thief2VrZip {
    private sealed class Entry {
        public byte[] Name;
        public uint Crc, Size, Offset;
        public ushort Time, Date;
    }
    private static readonly uint[] Table = MakeTable();
    private static uint[] MakeTable() {
        uint[] table = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int bit = 0; bit < 8; bit++) c = (c & 1) != 0 ? 0xedb88320U ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        return table;
    }
    private static Entry WriteEntry(BinaryWriter writer, Stream source, string name, long expectedSize) {
        if (source.Length != expectedSize) throw new IOException("Game file changed while packing: " + name);
        Entry entry = new Entry();
        entry.Name = Encoding.UTF8.GetBytes(name);
        if (entry.Name.Length > ushort.MaxValue) throw new IOException("Filename is too long.");
        entry.Size = checked((uint)source.Length);
        entry.Offset = checked((uint)writer.BaseStream.Position);
        DateTime now = DateTime.UtcNow;
        entry.Time = (ushort)((now.Hour << 11) | (now.Minute << 5) | (now.Second / 2));
        entry.Date = (ushort)(((now.Year - 1980) << 9) | (now.Month << 5) | now.Day);
        writer.Write(0x04034b50U); writer.Write((ushort)20);
        writer.Write((ushort)0x800); writer.Write((ushort)0);
        writer.Write(entry.Time); writer.Write(entry.Date);
        long crcOffset = writer.BaseStream.Position;
        writer.Write(0U); writer.Write(entry.Size); writer.Write(entry.Size);
        writer.Write((ushort)entry.Name.Length); writer.Write((ushort)0); writer.Write(entry.Name);
        byte[] buffer = new byte[1024 * 1024];
        uint crc = 0xffffffffU;
        long copied = 0;
        int count;
        while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
            for (int i = 0; i < count; i++) crc = Table[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
            writer.Write(buffer, 0, count);
            copied += count;
        }
        if (copied != expectedSize) throw new IOException("Incomplete game file: " + name);
        entry.Crc = crc ^ 0xffffffffU;
        long end = writer.BaseStream.Position;
        writer.BaseStream.Position = crcOffset; writer.Write(entry.Crc);
        writer.BaseStream.Position = end;
        return entry;
    }
    public static void Create(string output, string[] sources, string[] names, long[] sizes, byte[] manifest) {
        using (FileStream file = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (BinaryWriter writer = new BinaryWriter(file)) {
            List<Entry> entries = new List<Entry>();
            for (int i = 0; i < sources.Length; i++) {
                Console.WriteLine("Packing " + names[i]);
                using (FileStream source = new FileStream(sources[i], FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    entries.Add(WriteEntry(writer, source, names[i], sizes[i]));
                }
            }
            using (MemoryStream source = new MemoryStream(manifest)) {
                entries.Add(WriteEntry(writer, source, "manifest.json", manifest.Length));
            }
            uint directoryStart = checked((uint)file.Position);
            foreach (Entry entry in entries) {
                writer.Write(0x02014b50U); writer.Write((ushort)20); writer.Write((ushort)20);
                writer.Write((ushort)0x800); writer.Write((ushort)0);
                writer.Write(entry.Time); writer.Write(entry.Date); writer.Write(entry.Crc);
                writer.Write(entry.Size); writer.Write(entry.Size);
                writer.Write((ushort)entry.Name.Length);
                writer.Write((ushort)0); writer.Write((ushort)0); writer.Write((ushort)0);
                writer.Write((ushort)0); writer.Write(0U); writer.Write(entry.Offset); writer.Write(entry.Name);
            }
            uint directorySize = checked((uint)(file.Position - directoryStart));
            writer.Write(0x06054b50U); writer.Write((ushort)0); writer.Write((ushort)0);
            writer.Write((ushort)entries.Count); writer.Write((ushort)entries.Count);
            writer.Write(directorySize); writer.Write(directoryStart); writer.Write((ushort)0);
        }
    }
}
"@
    }
    Write-Host ("Creating VR package: {0} files, {1:N1} MiB" -f $files.Count, ($total / 1MB))
    [Thief2VrZip]::Create($temporary,
        [string[]]@($files | ForEach-Object { $_.Source }),
        [string[]]@($files | ForEach-Object { $_.Path }),
        [long[]]@($files | ForEach-Object { $_.Size }),
        [Text.Encoding]::UTF8.GetBytes($manifest))
    Move-Item -LiteralPath $temporary -Destination $output
    $temporary = $null
    Write-Host ""
    Write-Host "Ready: $output"
    Write-Host 'Choose this ZIP on the Thief II VR page. For standalone Quest, copy it to the headset first.'
    if (-not $NoPause) {
        Write-Host 'Press Enter to close'
        [void][Console]::ReadLine()
    }
    exit 0
} catch {
    if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
    Write-Host ("Could not create the game package: " + $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) {
        Write-Host 'Press Enter to close'
        [void][Console]::ReadLine()
    }
    exit 1
}
