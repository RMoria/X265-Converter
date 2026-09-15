<#
=====================================================================
  VIDEO  ->  H.265 / HEVC  BATCH CONVERTER   (PowerShell + WPF GUI)
=====================================================================

  Opvolger van convert.bat - één PowerShell-script met een grafische
  interface, meerdere bronmappen (incl. UNC), een herschikbare
  wachtrij, pauze/hervat, stop (direct of na huidige), live
  statistieken, cumulatieve totalen en een tijdsindicatie.

  Werkwijze per bestand:
    1. ffprobe: is het een videobestand, welke codec, hoe lang
    2. ffmpeg : encode naar de werkmap (standaard %TEMP%)
    3. verplaats het eindbestand naar de bronmap
    4. ondertitels meenemen naar de nieuwe naam
    5. pas na een geslaagde verplaatsing: origineel verwijderen

  Dubbelklikken: X265-Converter.cmd (de enige starter).

  Auteur : gegenereerd voor Rob Moria / 4-Rest
=====================================================================
#>

[CmdletBinding()]
param(
    # Bronmappen die bij het opstarten moeten worden toegevoegd.
    [string[]]$Path,

    # Wordt door X265-Converter.cmd meegegeven. Betekent: dit proces
    # heeft een consolevenster geërfd, dus meteen opnieuw starten als
    # proces ZONDER console en deze instantie afsluiten.
    [switch]$FromLauncher,

    # Aanroep vanuit een ander script of programma: één bestand omzetten.
    # -In is het volledige pad van de bron.
    [string]$In,

    # Het volledige pad van het resultaat. Dit wordt LETTERLIJK gebruikt:
    # er wordt geen '.x265' achter geplakt en er komt geen '(2)' bij als
    # het al bestaat. Wie het pad zelf opgeeft, krijgt precies dat pad.
    # Weggelaten? Dan gaat het resultaat als <naam>.x265.mkv naast de bron.
    #
    # Draait er al een instantie, dan wordt de opdracht daaraan doorgegeven
    # (achteraan de wachtrij) en sluit deze aanroep zichzelf meteen af.
    [string]$Out
)

# ---------------------------------------------------------------------
#  Versie
#
#  Staat hier bovenaan zodat het vangnet hieronder hem ook in het
#  foutenlogboek kan zetten: bij een melding is het eerste wat je wilt
#  weten welke versie er draaide.
#
#  Ophogen bij elke oplevering. Tweede cijfer erbij voor nieuw gedrag,
#  derde cijfer voor een reparatie. De wijzigingen per versie staan in
#  LEESMIJ-X265-Converter.md.
# ---------------------------------------------------------------------
$AppName    = 'X265 Converter'
$AppVersion = '1.6'
$AppDate    = '2026-09-15'
$AppTitle   = 'Video naar H.265 / HEVC'
$AppStamp   = ('{0} {1} ({2})' -f $AppName, $AppVersion, $AppDate)


# ---------------------------------------------------------------------
# 0a. Opnieuw starten zonder consolevenster
#
#     Dit is de oplossing voor het venster dat bleef staan. Eerder werd
#     het venster achteraf verborgen (-WindowStyle Hidden en ShowWindow),
#     maar dat werkt niet wanneer Windows Terminal de standaard terminal
#     is: dat venster is niet van conhost en trekt zich van ShowWindow
#     niets aan. Daarom wordt er nu voor het proces dat blijft leven
#     helemaal GEEN console meer aangemaakt: CreateNoWindow op een verse
#     ProcessStartInfo. De zichtbare instantie doet niets anders dan die
#     hidden instantie starten en zichzelf beëindigen.
#
#     Dit blok staat opzettelijk vóór alle Add-Type-aanroepen, zodat de
#     zichtbare instantie zo kort mogelijk leeft.
# ---------------------------------------------------------------------

function Get-RelaunchArguments {
    param([string]$ScriptPath, [string[]]$Folders, [string]$InFile = '', [string]$OutFile = '')

    $cmd = "& '" + ($ScriptPath -replace "'", "''") + "'"
    if ($Folders) {
        $q = @()
        foreach ($f in $Folders) { $q += ("'" + ($f -replace "'", "''") + "'") }
        if ($q.Count -gt 0) { $cmd = $cmd + ' -Path ' + ($q -join ',') }
    }

    # -In en -Out moeten mee naar de instantie die blijft leven, anders
    # gaat de opdracht van een aanroepend programma verloren op het moment
    # dat het script zichzelf zonder console herstart.
    if (-not [string]::IsNullOrWhiteSpace($InFile)) {
        $cmd = $cmd + " -In '" + ($InFile -replace "'", "''") + "'"
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $cmd = $cmd + " -Out '" + ($OutFile -replace "'", "''") + "'"
        }
    }
    return ('-NoProfile -ExecutionPolicy Bypass -STA -Command "' + $cmd + '"')
}

if ($FromLauncher) {

    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Definition }

    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = 'powershell.exe' }

    # Argumenten opbouwen. Geef GEEN -FromLauncher mee, anders blijft het
    # zichzelf herstarten.
    #
    # Let op: met -File kan een array niet worden doorgegeven; een tweede
    # -Path geeft dan "parameter specified more than once". Daarom -Command
    # met PowerShell-notatie, waarin enkele aanhalingstekens verdubbeld
    # worden.
    $argLine = Get-RelaunchArguments -ScriptPath $self -Folders $Path -InFile $In -OutFile $Out

    $relaunched = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $hostExe
        $psi.Arguments       = $argLine
        $psi.UseShellExecute = $false     # vereist voor CreateNoWindow
        $psi.CreateNoWindow  = $true      # <- hierdoor komt er geen console
        try { $psi.WorkingDirectory = (Split-Path -Parent $self) } catch { }

        [void][System.Diagnostics.Process]::Start($psi)
        $relaunched = $true
    }
    catch {
        Write-Host "Kon de verborgen instantie niet starten: $($_.Exception.Message)"
        Write-Host 'Het programma gaat verder in dit venster.'
        Start-Sleep -Seconds 2
    }

    if ($relaunched) { return }
    # anders: gewoon doorgaan in deze (zichtbare) instantie
}

# ---------------------------------------------------------------------
# 0b. STA-controle  (WPF vereist een Single Threaded Apartment)
#
#     Windows PowerShell 5.1 start standaard al in STA en de starter
#     geeft -STA expliciet mee; dit is het vangnet voor het geval het
#     script vanuit een MTA-host wordt aangeroepen.
# ---------------------------------------------------------------------

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {

    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Definition }

    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = 'powershell.exe' }

    $argLine = Get-RelaunchArguments -ScriptPath $self -Folders $Path -InFile $In -OutFile $Out

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $hostExe
        $psi.Arguments       = $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        [void][System.Diagnostics.Process]::Start($psi)
    }
    catch {
        # Niet stil weglopen: zonder venster en zonder melding zou het
        # programma gewoon lijken te verdwijnen.
        $detail = "Opnieuw starten in STA is mislukt: $($_.Exception.Message)"
        $lg = Get-ErrorLogPath
        if ($lg) { try { Add-Content -LiteralPath $lg -Value ((Get-Date -Format 's') + '  ' + $AppStamp + '  ' + $detail) -Encoding UTF8 } catch { } }
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [void][System.Windows.Forms.MessageBox]::Show($detail, 'X265 Converter')
        } catch { Write-Host $detail }
    }

    return
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# 1.  Assemblies
# ---------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------
#  Waar kan het foutenlogboek heen?
#
#  Naast het script, maar op een beheerde machine is die map vaak
#  alleen-lezen. Dan wijken we uit naar de profielmap. Dit staat hier
#  omdat het vangnet hieronder al moet werken voordat de rest van het
#  script is ingelezen.
# ---------------------------------------------------------------------
function Get-ErrorLogPath {
    $kandidaten = @()
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $kandidaten += $PSScriptRoot }
    if ($env:LOCALAPPDATA) { $kandidaten += (Join-Path $env:LOCALAPPDATA 'X265-Converter') }
    if ($env:TEMP)         { $kandidaten += (Join-Path $env:TEMP 'X265-Converter') }
    $kandidaten += $env:TEMP

    foreach ($d in $kandidaten) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $d -PathType Container -ErrorAction Stop)) {
                New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
            }
            $f = Join-Path $d 'X265-Converter.error.log'
            Add-Content -LiteralPath $f -Value '' -ErrorAction Stop
            return $f
        }
        catch { continue }
    }
    return $null
}

# ---------------------------------------------------------------------
# 1b. Vangnet: onverwachte fouten zichtbaar maken
#     (de console is verborgen, dus zonder dit zou het venster
#      geruisloos verdwijnen)
# ---------------------------------------------------------------------

trap {
    $detail = "$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n`r`n$($_.InvocationInfo.PositionMessage)`r`n`r`n$($_.ScriptStackTrace)"
    $lg = Get-ErrorLogPath
    $kop = ('{0}   {1}' -f $AppStamp, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($lg) { try { Set-Content -LiteralPath $lg -Value ($kop + "`r`n`r`n" + $detail) -Encoding UTF8 -Force } catch { } }
    try {
        [System.Windows.MessageBox]::Show(
            ("Er is een onverwachte fout opgetreden. Het venster wordt gesloten." +
             $(if ($lg) { "`r`nLogboek: $lg" } else { '' }) + "`r`n`r`n$detail"),
            'X265 Converter - fout', 'OK', 'Error') | Out-Null
    } catch { }
    break
}

# ---------------------------------------------------------------------
# 2.  Hulptypes  (C#)
# ---------------------------------------------------------------------

if (-not ('X265.NativeProc' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace X265
{
    public static class NativeProc
    {
        [DllImport("ntdll.dll", SetLastError = true)]
        private static extern uint NtSuspendProcess(IntPtr processHandle);

        [DllImport("ntdll.dll", SetLastError = true)]
        private static extern uint NtResumeProcess(IntPtr processHandle);

        public static bool Suspend(IntPtr h)
        {
            try { return NtSuspendProcess(h) == 0; } catch { return false; }
        }

        public static bool Resume(IntPtr h)
        {
            try { return NtResumeProcess(h) == 0; } catch { return false; }
        }

    }
}
'@
}


# ---------------------------------------------------------------------
# 2b. Moderne mapkiezer (Explorer-dialoog met adresbalk, UNC en
#     meervoudige selectie).  Valt terug op de oude dialoog als de
#     COM-interop om welke reden dan ook faalt.
# ---------------------------------------------------------------------

if (-not ('X265.FolderPicker' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace X265
{
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemArray
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppvOut);
        void GetPropertyStore(int flags, ref Guid riid, out IntPtr ppv);
        void GetPropertyDescriptionList(IntPtr keyType, ref Guid riid, out IntPtr ppv);
        void GetAttributes(int dwAttribFlags, uint sfgaoMask, out uint psfgaoAttribs);
        void GetCount(out uint pdwNumItems);
        void GetItemAt(uint dwIndex, out IShellItem ppsi);
        void EnumItems(out IntPtr ppenumShellItems);
    }

    // BELANGRIJK: de COM-interoplaag neemt de methoden van een basis-
    // interface NIET mee in de vtable. Alle methoden van IModalWindow en
    // IFileDialog moeten daarom hier letterlijk herhaald worden, in
    // precies dezelfde volgorde, voordat GetResults/GetSelectedItems
    // op de juiste slots terechtkomen.
    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog
    {
        // --- IModalWindow ---
        [PreserveSig] int Show(IntPtr hwndOwner);
        // --- IFileDialog ---
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        // --- IFileOpenDialog ---
        void GetResults(out IShellItemArray ppenum);
        void GetSelectedItems(out IShellItemArray ppsai);
    }

    [ComImport, ClassInterface(ClassInterfaceType.None),
     Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRcw { }

    public static class FolderPicker
    {
        private const uint FOS_PICKFOLDERS      = 0x00000020;
        private const uint FOS_FORCEFILESYSTEM  = 0x00000040;
        private const uint FOS_ALLOWMULTISELECT = 0x00000200;
        private const uint FOS_PATHMUSTEXIST    = 0x00000800;
        private const uint SIGDN_FILESYSPATH    = 0x80058000;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
            IntPtr pbc,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out object ppv);

        private static string PathOf(IShellItem item)
        {
            IntPtr p = IntPtr.Zero;
            try
            {
                item.GetDisplayName(SIGDN_FILESYSPATH, out p);
                if (p == IntPtr.Zero) { return null; }
                return Marshal.PtrToStringUni(p);
            }
            finally
            {
                if (p != IntPtr.Zero) { Marshal.FreeCoTaskMem(p); }
            }
        }

        /// <summary>
        /// Opent de Explorer-mapkiezer. Geeft de gekozen paden terug,
        /// of een lege reeks wanneer de gebruiker annuleert.
        /// </summary>
        public static string[] Pick(IntPtr owner, string title, string initialPath, bool multiSelect)
        {
            List<string> result = new List<string>();
            IFileOpenDialog dlg = (IFileOpenDialog)(new FileOpenDialogRcw());

            uint options;
            dlg.GetOptions(out options);
            options = options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
            if (multiSelect) { options = options | FOS_ALLOWMULTISELECT; }
            dlg.SetOptions(options);

            if (!string.IsNullOrEmpty(title)) { dlg.SetTitle(title); }
            dlg.SetOkButtonLabel("Deze map gebruiken");

            if (!string.IsNullOrEmpty(initialPath))
            {
                try
                {
                    Guid iid = typeof(IShellItem).GUID;
                    object item;
                    SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out item);
                    if (item != null) { dlg.SetFolder((IShellItem)item); }
                }
                catch { }
            }

            int hr = dlg.Show(owner);
            if (hr != 0) { return result.ToArray(); }   // 0x800704C7 = geannuleerd

            IShellItemArray items;
            dlg.GetResults(out items);
            uint count;
            items.GetCount(out count);
            for (uint i = 0; i < count; i++)
            {
                IShellItem si;
                items.GetItemAt(i, out si);
                string p = PathOf(si);
                if (!string.IsNullOrEmpty(p)) { result.Add(p); }
            }
            return result.ToArray();
        }
    }
}
'@
}

# ---------------------------------------------------------------------
# 2c. Regel in de bestandslijst
# ---------------------------------------------------------------------

if (-not ('X265.FileJob' -as [type])) {
$wpfBase = [System.Windows.Threading.Dispatcher].Assembly.Location
Add-Type -ReferencedAssemblies @($wpfBase) -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Threading;

namespace X265
{
    public class FileJob : INotifyPropertyChanged
    {
        private Dispatcher _disp;

        public FileJob() { }
        public FileJob(Dispatcher d) { _disp = d; }

        public event PropertyChangedEventHandler PropertyChanged;

        private void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h == null) return;
            PropertyChangedEventArgs a = new PropertyChangedEventArgs(name);
            if (_disp != null && !_disp.CheckAccess())
                _disp.BeginInvoke((Action)(() => h(this, a)));
            else
                h(this, a);
        }

        // ---- gebonden aan de DataGrid -----------------------------
        // Al-HEVC-regels mogen niet worden aangevinkt. De setter weigert
        // dat hard, zodat geen enkele weg eromheen leidt.
        private bool _include = true;
        public bool Include
        {
            get { return _include; }
            set
            {
                bool v = value;
                if (v && _isHevc) { v = false; }
                if (_include == v) { return; }
                _include = v;
                Raise("Include");
            }
        }

        private string _name = "";
        public string Name { get { return _name; } set { _name = value; Raise("Name"); } }

        private string _folder = "";
        public string Folder { get { return _folder; } set { _folder = value; Raise("Folder"); } }

        private string _codec = "";
        public string Codec { get { return _codec; } set { _codec = value; Raise("Codec"); } }

        private string _sizeText = "";
        public string SizeText { get { return _sizeText; } set { _sizeText = value; Raise("SizeText"); } }

        private string _durationText = "";
        public string DurationText { get { return _durationText; } set { _durationText = value; Raise("DurationText"); } }

        private string _status = "In wachtrij";
        public string Status { get { return _status; } set { _status = value; Raise("Status"); } }

        private string _resultText = "";
        public string ResultText { get { return _resultText; } set { _resultText = value; Raise("ResultText"); } }

        private string _newSizeText = "";
        public string NewSizeText { get { return _newSizeText; } set { _newSizeText = value; Raise("NewSizeText"); } }

        // Positie in de wachtrij, als drie cijfers met voorloopnullen.
        // Leeg wanneer de regel niet in de wachtrij staat.
        private string _queueText = "";
        public string QueueText { get { return _queueText; } set { _queueText = value; Raise("QueueText"); } }

        // Al HEVC? Dan is aanvinken uitgesloten en is het vinkje grijs.
        private bool _isHevc = false;
        public bool IsHevc
        {
            get { return _isHevc; }
            set
            {
                if (_isHevc == value) { return; }
                _isHevc = value;
                if (_isHevc && _include) { _include = false; Raise("Include"); }
                Raise("IsHevc");
                Raise("CanInclude");
            }
        }

        /// <summary>Onwaar voor al-HEVC-regels; hieraan hangt IsEnabled van het vinkje.</summary>
        public bool CanInclude { get { return !_isHevc; } }

        // ---- niet gebonden, alleen data ---------------------------
        public string FullPath   { get; set; }
        public long   SizeBytes  { get; set; }
        public long   NewBytes   { get; set; }
        public double DurationSec{ get; set; }
        public bool   Queued     { get; set; }
        public int    QueuePos   { get; set; }
        public double EncodeSec  { get; set; }
        public string RawCodec   { get; set; }

        // Vast uitvoerpad, meegegeven met -Out op de opdrachtregel. Leeg
        // betekent: zelf een naam afleiden (<naam>.x265.mkv).
        public string OutPath    { get; set; }
    }
}
'@
}
