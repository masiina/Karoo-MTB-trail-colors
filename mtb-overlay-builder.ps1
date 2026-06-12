<#
.SYNOPSIS
    MTB Trail Overlay Map Builder v1.0
.DESCRIPTION
    Windows-native PowerShell WinForms GUI application for building and pushing
    MTB trail overlay maps to a Hammerhead Karoo device.
.NOTES
    Requires: Windows 10/11, PowerShell 5.1+
    Auto-downloads: JRE 17 (~42 MB), Mapsforge map-writer JAR (~6 MB),
                    Osmosis (~8 MB), Android Platform Tools (~15 MB)
#>

#requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# REGION DATABASE
# ============================================================
$RegionData = [ordered]@{
    'Finland'     = @{ Key = 'finland';     Url = 'https://download.geofabrik.de/europe/finland-latest.osm.pbf';        Bbox = '59.0,19.0,70.0,32.0';    Start = '61.5,25.0' }
    'Germany'     = @{ Key = 'germany';     Url = 'https://download.geofabrik.de/europe/germany-latest.osm.pbf';        Bbox = '46.0,5.0,55.5,15.5';     Start = '51.0,10.5' }
    'Norway'      = @{ Key = 'norway';      Url = 'https://download.geofabrik.de/europe/norway-latest.osm.pbf';         Bbox = '57.0,4.0,71.5,31.5';     Start = '65.0,14.0' }
    'Sweden'      = @{ Key = 'sweden';      Url = 'https://download.geofabrik.de/europe/sweden-latest.osm.pbf';         Bbox = '55.0,10.0,69.5,24.5';    Start = '62.0,15.0' }
    'Estonia'     = @{ Key = 'estonia';     Url = 'https://download.geofabrik.de/europe/estonia-latest.osm.pbf';        Bbox = '57.5,21.5,60.0,28.5';    Start = '59.0,25.0' }
    'Spain'       = @{ Key = 'spain';       Url = 'https://download.geofabrik.de/europe/spain-latest.osm.pbf';          Bbox = '36.0,-9.5,43.5,3.5';     Start = '40.0,-3.5' }
    'France'      = @{ Key = 'france';      Url = 'https://download.geofabrik.de/europe/france-latest.osm.pbf';         Bbox = '41.0,-5.5,51.5,10.0';    Start = '46.5,2.0' }
    'Italy'       = @{ Key = 'italy';       Url = 'https://download.geofabrik.de/europe/italy-latest.osm.pbf';          Bbox = '36.0,6.5,47.5,18.5';     Start = '42.5,12.5' }
    'Austria'     = @{ Key = 'austria';     Url = 'https://download.geofabrik.de/europe/austria-latest.osm.pbf';        Bbox = '46.0,9.5,49.5,17.5';     Start = '47.5,13.5' }
    'Switzerland' = @{ Key = 'switzerland'; Url = 'https://download.geofabrik.de/europe/switzerland-latest.osm.pbf';    Bbox = '45.5,5.5,48.0,11.0';     Start = '46.8,8.0' }
}

# ============================================================
# CONSTANTS
# ============================================================
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$BuildDir = Join-Path $ScriptDir 'build-tools'
$OsmosisVer = '0.48.3'
$MapsforgeVer = '0.20.0'  # Used for Maven Central JAR download URL

# ============================================================
# HELPER: Format file size as human-readable string
# ============================================================
function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -gt 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -gt 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -gt 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# ============================================================
# FAST DOWNLOAD HELPER WITH PROGRESS
# Uses WebClient.DownloadFileAsync so the UI stays responsive.
# Polls IsBusy + file size on disk to show real-time progress
# in the status bar. Streams directly to disk (fast).
# ============================================================
function Invoke-FastDownload {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $fileName = Split-Path $OutFile -Leaf
    Add-Log "  Downloading $fileName..."
    Set-Status "Downloading $fileName..."
    [System.Windows.Forms.Application]::DoEvents()

    # Try to get Content-Length for percentage progress
    $totalBytes = 0
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.UserAgent = 'Mozilla/5.0'
        $req.Timeout = 8000
        $resp = $req.GetResponse()
        $totalBytes = $resp.ContentLength
        $resp.Close()
    } catch {
        # HEAD not supported or failed — show size-only progress
        $totalBytes = 0
    }

    if ($totalBytes -gt 0) {
        $totalStr = Format-FileSize $totalBytes
        Add-Log "  File size: $totalStr"
    }

    $wc = New-Object System.Net.WebClient

    try {
        $wc.DownloadFileAsync([Uri]$Url, $OutFile)

        # Poll IsBusy until download completes, showing file size progress
        $lastSizeStr = ''
        while ($wc.IsBusy) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 300

            if (Test-Path $OutFile) {
                $currentSize = (Get-Item $OutFile).Length
                if ($currentSize -gt 0) {
                    $sizeStr = Format-FileSize $currentSize

                    if ($totalBytes -gt 0) {
                        $pct = [math]::Floor(($currentSize / $totalBytes) * 100)
                        if ($pct -gt 100) { $pct = 100 }
                        $statusText = "Downloading $fileName... $pct% ($sizeStr / $totalStr)"
                    } else {
                        $statusText = "Downloading $fileName... $sizeStr"
                    }
                    if ($statusText -ne $lastSizeStr) {
                        Set-Status $statusText
                        $lastSizeStr = $statusText
                    }
                }
            }
        }

        # Check if file exists and has content
        if (-not (Test-Path $OutFile)) {
            throw "Download failed for ${fileName}: file not found after download"
        }
        $finalSize = (Get-Item $OutFile).Length
        if ($finalSize -eq 0) {
            throw "Download failed for ${fileName}: file is empty (0 bytes)"
        }
    } finally {
        if ($wc.IsBusy) { $wc.CancelAsync() }
        $wc.Dispose()
    }

    # Report final size
    $size = (Get-Item $OutFile).Length
    $sizeStr = Format-FileSize $size
    Add-Log "  Downloaded $fileName ($sizeStr)"
}

# ============================================================
# GLOBAL UI REFS (set during form creation)
# ============================================================
$form = $null
$countryCombo = $null
$buildBtn = $null
$pushBtn = $null
$refreshBtn = $null
$logBox = $null
$statusLabel = $null
$script:titleLabel = $null
$script:countryLabel = $null

# ============================================================
# THREAD-SAFE UI HELPERS
# ============================================================
function Add-Log {
    param([string]$Message)
    if ($logBox -and -not $logBox.IsDisposed) {
        $logBox.AppendText("$Message`r`n")
        $logBox.ScrollToCaret()
    }
}

function Set-Status {
    param([string]$Text)
    if ($statusLabel -and -not $statusLabel.IsDisposed) {
        $statusLabel.Text = "Status: $Text"
        $form.Refresh()
    }
}

function Set-ButtonsEnabled {
    param([bool]$Build, [bool]$Push, [bool]$Refresh)
    if ($buildBtn -and -not $buildBtn.IsDisposed) {
        $buildBtn.Enabled = $Build
    }
    if ($pushBtn -and -not $pushBtn.IsDisposed) {
        $pushBtn.Enabled = $Push
    }
    if ($refreshBtn -and -not $refreshBtn.IsDisposed) {
        $refreshBtn.Enabled = $Refresh
    }
}

# ============================================================
# ENSURE THEME FILE
# ============================================================
function Ensure-ThemeFile {
    $themeFile = Join-Path $ScriptDir 'data\offline_v15.xml'
    if (Test-Path $themeFile) {
        Add-Log "  [OK] Theme file: data\offline_v15.xml"
        return
    }

    Add-Log '  Theme file not found. Restoring from embedded copy...'
    $dataDir = Join-Path $ScriptDir 'data'
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    Set-Content -Path $themeFile -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<rendertheme xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" map-background="#dcd5d0"
    version="1" xmlns="http://mapsforge.org/renderTheme"
    xsi:schemaLocation="http://mapsforge.org/renderTheme https://raw.githubusercontent.com/mapsforge/vtm/master/resources/rendertheme.xsd">

    <!-- AREA STYLES -->
    <style-area fill="#6aabb8" id="water" mesh="true"/>

    <!-- LINE CASINGS -->
    <style-line id="unpaved_casing" stroke="#9e844c" cap="round"/>
    <style-line id="paved_cycleway_casing" stroke="#327a04" cap="round"/>
    <style-line id="track_chasing" stroke="#ada02a" cap="round" width="1.1"/>
    <style-line id="MTB_0_chasing" stroke="#22AA22" cap="round" width="0.9"/>
    <style-line id="MTB_1_chasing" stroke="#88CC00" cap="round" width="0.9"/>
    <style-line id="MTB_2_chasing" stroke="#FFCC00" cap="round" width="0.9"/>
    <style-line id="MTB_3_chasing" stroke="#FF8800" cap="round" width="0.9"/>
    <style-line id="MTB_4_chasing" stroke="#DD0000" cap="round" width="0.9"/>
    <style-line id="MTB_5_chasing" stroke="#DD0000" cap="round" width="0.9"/>


    <!-- LINE STYLES -->
    <style-line id="path" stroke="#606060" dasharray="6,6" cap="round" width="0.7"/>
    <style-line id="track" stroke="#75703f" dasharray="6,6" cap="round" width="1.0"/>

    <style-line id="cycling_path" stroke="#ffffff" dasharray="8,8" cap="round" width="0.9"/>
    <style-line id="MTB_path" stroke="#000000" dasharray="5,6" cap="round" width="0.4"/>
    <style-line id="ferry" stroke="#6666FF" dasharray="8,8" cap="round" width="0.9"/>

    <!-- Base style for fixed width lines -->
    <style-line cap="butt" fix="true" id="fix" width="1.0"/>

    <!-- Water line styles -->
    <style-line cap="butt" id="water" stroke="#6aabb8" width="1.0"/>
    <style-line fix="false" id="river" stroke="#6aabb8" use="water"/>

    <!-- Text styles -->
    <style-text id="poi_label" caption="true" dy="-15" fill="#2d51bc" font-family="thin"
        k="name" size="11" stroke="#ffffff" stroke-width="2.0" style="bold" />

    <!-- Road Labels - need to set priority and size where used, and override fill if needed -->
    <style-text id="road_label" k="name" fill="#444444" stroke="#ffffff" stroke-width="2.0" style="bold"/>

    <!-- STYLE ASSIGNMENT RULES -->

    <!-- Land vs. sea -->
    <m e="way" k="natural" v="issea|sea">
        <area use="water"/>
    </m>
    <m e="way" k="natural" v="nosea">
        <area mesh="true" fill="#dcd5d0"/>
    </m>

    <!-- Land use, natural, leisure, amenity areas -->
    <m k="landuse">
        <m v="meadow">
            <area mesh="true" fill="#bfe0ad"/>
        </m>
        <m v="residential">
            <area mesh="true" fill="#c2c2bc"/>
        </m>
        <m v="allotments">
            <area mesh="true" fill="#cfac7c"/>
        </m>
        <m v="commercial|retail">
            <area mesh="true" fill="#d4d4d4"/>
        </m>
        <m v="farm|farmyard|farmland|orchard|vineyard">
            <area mesh="true" fill="#a7c28f"/>
        </m>
        <m v="quarry">
            <area mesh="true" fill="#b8b1ad"/>
        </m>
        <m v="industrial|railway">
            <area mesh="true" fill="#d4c3d6"/>
        </m>
        <m v="cemetery">
            <area mesh="true" fill="#bdc7b3"/>
        </m>
    </m>
    <m k="amenity">
        <m v="kindergarten|school|college|university">
            <area mesh="true" fill="#c2c180"/>
            <line cap="butt" fix="true" stroke="#9aabae" width="1.0"/>
        </m>
        <m v="hospital">
            <area mesh="true" fill="#d9c7ab"/>
        </m>
    </m>
    <m k="landuse">
        <m v="recreation_ground">
            <area mesh="true" fill="#9ac56e"/>
        </m>
        <m v="brownfield">
            <area mesh="true" fill="#b9baad"/>
        </m>
    </m>
    <m k="leisure" v="park|common|green|golf_course|pitch">
        <area mesh="true" fill="#9ac56e"/>
    </m>
    <m k="natural">
        <m k="natural" v="grassland|scrub">
            <area mesh="true" fill="#8ed496"/>
        </m>
        <m v="sand|beach">
            <area mesh="true" fill="#f5e8d6"/>
        </m>
    </m>

    <m k="amenity" v="parking">
        <area mesh="true" fill="#999999"/>
    </m>

    <m k="landuse|natural" v="forest|wood">
        <area mesh="true" fill="#a8bc9a"/>
    </m>

    <!-- keep grass above forest:wood and leisure:park! -->
    <!-- http://wiki.openstreetmap.org/wiki/Proposed_features/conservation,
            often serves as background for leisure=nature_reserve -->
    <m k="landuse" v="grass">
        <area mesh="true" fill="#c4deab"/>
    </m>

    <m k="leisure" v="garden">
        <area mesh="true" fill="#cce0b8"/>
    </m>

    <m k="landuse" v="reservoir|basin">
        <area use="water"/>
    </m>
    <!-- End landuse, natural, leisure, tourism, amenity areas -->

    <!-- Overlay map areas (must be last area layer so overlay draws on top) -->
    <m k="natural" v="rock|bare_rock|stone|scree|glacier|cliff">
        <area mesh="true" fill="#d5c8af" stroke="#8b7355" stroke-width="0.3"/>
        <area src="file:/icons/bare_rock.svg" symbol-height="64" symbol-width="64"/>
    </m>

    <!-- Waterways (rivers, streams, etc.) -->
    <m e="way" k="waterway">
        <m v="ditch|drain" zoom-min="14">
            <line use="water" width="0.2"/>
        </m>
        <m v="stream" zoom-min="13">
            <line use="water" width="0.4"/>
        </m>
        <m v="canal">
            <line use="river" width="-0.3"/>
        </m>
        <m v="river">
            <m zoom-min="12">
                <line use="river" width="0.5"/>
            </m>
            <m zoom-min="10">
                <line use="water" width="0.3"/>
            </m>
            <m zoom-min="8">
                <line use="water" width="0.1"/>
            </m>
        </m>
        <m v="riverbank|dock">
            <!-- Using mesh=true for areas causes problems below ZL 12 -->
            <!-- Using just lines at lower ZL is not a good solution (big rivers look bad) -->
            <area use="water" mesh="false"/>
        </m>
        <m v="weir">
            <line stroke="#000088" use="fix"/>
        </m>
        <m v="dam" zoom-min="12">
            <line stroke="#ababab" use="fix" width="0.2"/>
        </m>
        <m k="lock" v="yes|true">
            <line stroke="#f8f8f8" use="fix" width="0.5"/>
        </m>
    </m>

    <!-- Closed natural water features (e.g. lakes) -->
    <m e="way">
        <m closed="yes" k="natural" v="water">
            <area use="water" />
            <caption font-family="thin" area-size="0.2" fill="#000000" k="name" size="14"/>
        </m>
    </m>

    <!-- partially transparent areas, draw later. these can overlap water and land -->
    <m k="leisure" v="nature_reserve">
        <area mesh="true" fill="#9988b8b3"/>
    </m>
    <m k="landuse" v="military">
        <area mesh="true" fill="#99b89488"/>
        <caption font-family="thin" area-size="0.2" fill="#000000" k="name" size="14"/>
    </m>

    <!-- Railway -->
    <m e="way" k="railway">
        <m v="station">
            <area fill="#dbdbc9" stroke="#707070" stroke-width="0.3"/>
        </m>
        <!-- Railway bridge casings (TODO - needs work?) -->
        <m zoom-min="14">
            <m k="bridge" v="yes|true">
                <m v="tram|subway|light_rail|narrow_gauge">
                    <line cap="butt" fix="true" stroke="#777777" width="0.9"/>
                </m>
                <m v="rail">
                    <line cap="butt" fix="true" stroke="#777777" width="0.9"/>
                </m>
            </m>
        </m>
        <!--- Rail: use a line pattern above zoom 13 -->
        <m v="rail|turntable" zoom-min="14">
            <line cap="butt" fix="true" stipple="10" stipple-stroke="#ffffff"
                  stipple-width="0.8" stroke="#666666" width="2.0"/>
        </m>
        <m v="rail|turntable" zoom-max="13">
            <line cap="butt" fix="true" stroke="#ddaa9988" width="1.0"/>
        </m>
        <m v="tram" zoom-min="15">
            <line fix="true" stroke="#887766" width="1.0"/>
        </m>
        <m v="light_rail|subway|narrow_gauge" zoom-min="14">
            <line stroke="#999999" width="0.25"/>
        </m>
        <!-- Other tag values such as disused, spur, abandoned, preserved... --> 
        <m k="railway" v="~">
            <line cap="butt" fix="true" stroke="#cccccc" width="0.6"/>
        </m>
    </m>

    <!-- airport area features -->
    <m e="way" k="aeroway" v="aerodrome|apron|helipad">
        <area mesh="true" fill="#c7c7b1"/>
        <caption font-family="thin" area-size="0.2" fill="#000000" k="name" size="14"/>
    </m>
    <m e="way" k="aeroway" v="terminal">
        <area mesh="true" fill="#c2c180"/>
    </m>

    <!-- buildings -->
    <m e="way" k="building" v="*" zoom-min="17">
        <area mesh="true" fill="#a29186" stroke="#958175" stroke-width="0.25"/>
    </m>

    <!-- elevation contours -->
    <m e="way" k="natural" v="minor_contour_line" zoom-min="14">
        <line stroke="#979797" width="0.25"/>
    </m>
    <m e="way" k="natural" v="major_contour_line" zoom-min="10">
        <line stroke="#979797" width="0.75"/>
        <text k="name" caption="true" size="12" priority="5" fill="#444444" stroke="#ffffff" stroke-width="2.0" style="bold"/>
    </m>

    <!-- runway lines -->
    <m e="way" k="aeroway" v="runway|taxiway">
        <m k="*" v="*" zoom-min="10" zoom-max="12">
            <line stroke="#a6a5a2" width="1.5"/>
        </m>
        <m k="*" v="*" zoom-min="13">
            <line stroke="#a6a5a2" width="2.0"/>
        </m>
    </m>

    <!-- aerialways (gondola, cablecar, chair-lift, etc.) -->
    <m e="way" k="aerialway" v="*">
        <line stroke="#624d41" width="0.3"/>
    </m>

    <!-- bridleway (horses) -->
    <m e="way" k="highway" v="bridleway">
        <line use="path" stroke="#69b31b"/>
    </m>

    <!-- Cycling networks -->
    <m e="way" select="first">
        <m k="icn" v="yes" zoom-min="10">
            <m k="bridge" v="yes|true">
                <line stroke="#a2c851" cap="butt" width="4.2"/>
            </m>
            <m k="bridge" v="~">
                <line stroke="#a2c851" width="4.2"/>
            </m>
        </m>
        <m e="way" k="ncn" v="yes" zoom-min="11">
            <m k="bridge" v="yes|true">
                <line stroke="#d1837b" cap="butt" width="4.2"/>
            </m>
            <m k="bridge" v="~">
                <line stroke="#d1837b" width="4.2"/>
            </m>
        </m>
        <m k="rcn" v="yes" zoom-min="12">
            <m k="bridge" v="yes|true">
                <line stroke="#b77bb5" cap="butt" width="4.2"/>
            </m>
            <m k="bridge" v="~">
                <line stroke="#b77bb5" width="4.2"/>
            </m>
        </m>
        <m k="lcn" v="yes" zoom-min="13">
            <m k="bridge" v="yes|true">
                <line stroke="#4e4ede" cap="butt" width="4.2"/>
            </m>
            <m k="bridge" v="~">
                <line stroke="#4e4ede" width="4.2"/>
            </m>
        </m>
    </m>

    <!-- footway (separate bicycle-allowed from other)-->
    <m e="way" k="highway" v="footway">
        <m select="first">
            <m k="bicycle" v="yes|designated">
                <line use="cycling_path"/>
            </m>
            <m k="footway" v="sidewalk" zoom-min="15">
                <!-- Not sure if there is a better way to not display sidewalks -->
                <line width="0.0"/>
            </m>
            <m k="~" v="~">
                <line use="track_chasing"/>
                <line use="path"/>
            </m>
        </m>
    </m>

    <!-- service roads - separate parking aisle and driveway from other service roads -->
    <m e="way" k="highway" v="service">
        <m k="service" v="driveway" zoom-min="17">
            <line stroke="#f2f5ed" cap="round" dasharray="6,4" width="0.4"/>
        </m>
        <m k="service" v="parking_aisle" zoom-min="14">
            <line stroke="#f2f5ed" cap="round" width="0.6"/>
        </m>
        <m k="service" v="alley" zoom-min="14">
            <line stroke="#f2f5ed" cap="round" width="0.85"/>
        </m>
        <m k="service" v="~" zoom-min="14">
            <line stroke="#f2f5ed" cap="round" width="0.85"/>
        </m>
    </m>

    <!-- pedestrian highways -->
    <m e="way" k="highway" v="pedestrian">
        <m zoom-min="14">
            <line stroke="#f2f5ed" cap="round" width="0.9"/>
            <text use="road_label" size="12" priority="15"/>
        </m>
    </m>
    <m e="way" k="highway" v="cycleway">
        <!-- differentiate unpaved from paved -->
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel">
            <line use="unpaved_casing" width="1.2"/>
        </m>
        <m k="surface" v="~">
            <line use="paved_cycleway_casing" width="1.2"/>
        </m>
    </m>
    <m e="way" k="highway" v="residential|living_street">
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel" zoom-min="13">
            <line use="unpaved_casing" width="2.2"/>
        </m>
        <m k="surface" v="~">
            <m k="cycleway" v="*" zoom-min="13">
                <m k="bridge" v="yes|true">
                    <line use="paved_cycleway_casing" cap="butt" width="1.9"/>
                </m>
                <m k="bridge" v="~">
                    <line use="paved_cycleway_casing" width="1.9"/>
                </m>
            </m>
            <m k="cycleway" v="~" zoom-min="15">
                <m k="bridge" v="yes|true">
                    <line stroke="#707070" cap="butt" width="1.5"/>
                </m>
                <m k="bridge" v="~">
                    <line stroke="#707070" cap="round" width="1.5"/>
                </m>
            </m>
        </m>
    </m>

    <m e="way" k="highway" v="unclassified|road">
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel" zoom-min="12">
            <line use="unpaved_casing" width="2.4"/>
        </m>
        <m k="surface" v="~">
            <m k="cycleway" v="*" zoom-min="12">
                <m k="bridge" v="yes|true">
                    <line use="paved_cycleway_casing" cap="butt" width="2.1"/>
                </m>
                <m k="bridge" v="~">
                    <line use="paved_cycleway_casing" width="2.1"/>
                </m>
            </m>
            <m k="cycleway" v="~" zoom-min="14">
                <m k="bridge" v="yes|true">
                    <line stroke="#707070" cap="butt" width="1.7"/>
                </m>
                <m k="bridge" v="~">
                    <line stroke="#707070" cap="round" width="1.7"/>
                </m>
            </m>
        </m>
    </m>

    <m e="way" k="highway" v="tertiary|tertiary_link">
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel" zoom-min="12">
            <line use="unpaved_casing" width="2.6"/>
        </m>
        <m k="surface" v="~">
            <m k="cycleway" v="*" zoom-min="12">
                <m k="bridge" v="yes|true">
                    <line use="paved_cycleway_casing" cap="butt" width="2.3"/>
                </m>
                <m k="bridge" v="~">
                    <line use="paved_cycleway_casing" width="2.3"/>
                </m>
            </m>
            <m k="cycleway" v="~" zoom-min="14">
                <m k="bridge" v="yes|true">
                    <line stroke="#707070" cap="butt" width="1.9"/>
                </m>
                <m k="bridge" v="~">
                    <line stroke="#707070" cap="round" width="1.9"/>
                </m>
            </m>
        </m>
    </m>

    <m e="way" k="highway" v="secondary|secondary_link">
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel" zoom-min="10">
            <line use="unpaved_casing" width="2.8"/>
        </m>
        <m k="surface" v="~">
            <m k="cycleway" v="*" zoom-min="10">
                <m k="bridge" v="yes|true">
                    <line use="paved_cycleway_casing" cap="butt" width="2.5"/>
                </m>
                <m k="bridge" v="~">
                    <line use="paved_cycleway_casing" width="2.5"/>
                </m>
            </m>
            <m k="cycleway" v="~" zoom-min="13">
                <m k="bridge" v="yes|true">
                    <line stroke="#707070" cap="butt" width="2.0"/>
                </m>
                <m k="bridge" v="~">
                    <line stroke="#707070" cap="round" width="2.0"/>
                </m>
            </m>
        </m>
    </m>

    <m e="way" k="highway" v="primary|primary_link">
        <m k="surface" v="unpaved|compacted|ground|gravel|dirt|grass|sand|fine_gravel" zoom-min="10">
            <line use="unpaved_casing" width="2.8"/>
        </m>
        <m k="surface" v="~">
            <m k="cycleway" v="*" zoom-min="10">
                <m k="bridge" v="yes|true">
                    <line use="paved_cycleway_casing" cap="butt" width="2.5"/>
                </m>
                <m k="bridge" v="~">
                    <line use="paved_cycleway_casing" width="2.5"/>
                </m>
            </m>
            <m k="cycleway" v="~" zoom-min="12">
                <m k="bridge" v="yes|true">
                    <line stroke="#707070" cap="butt" width="2.3"/>
                </m>
                <m k="bridge" v="~">
                    <line stroke="#707070" cap="round" width="2.3"/>
                </m>
            </m>
        </m>
    </m>

    <!-- motorways and trunk roads - no casing -->
    <m e="way" k="highway" v="motorway|motorway_link|trunk|trunk_link">
        <line stroke="#dbb042" width="1.6"/>
        <text use="road_label" size="13" priority="14"/>
    </m>

    <!-- inner fill and labels for roads -->

    <!-- TODO - check for mtb tags -->
    <m e="way" k="highway" v="residential|living_street">
        <m zoom-min="15">
            <line stroke="#ffffff" cap="round" width="1.2"/>
        </m>
        <m zoom-max="14" zoom-min="13">
            <line stroke="#ffffff" cap="round" width="1.0"/>
        </m>
        <m zoom-min="13">
            <text use="road_label" size="13" priority="8"/>
        </m>
    </m>
    <m e="way" k="highway" v="unclassified|road">
        <m zoom-min="15">
            <line stroke="#ffffff" cap="round" width="1.4"/>
        </m>
        <m zoom-max="14" zoom-min="12">
            <line stroke="#ffffff" cap="round" width="1.2"/>
        </m>
        <m zoom-min="12">
            <text use="road_label" size="13" priority="9"/>
        </m>
    </m>
    <m e="way" k="highway" v="tertiary|tertiary_link">
        <m zoom-min="14">
            <line stroke="#ffffff" cap="round" width="1.6"/>
        </m>
        <m zoom-max="13" zoom-min="11">
            <line stroke="#ffffff" cap="round" width="1.4"/>
        </m>
        <m zoom-min="11">
            <text use="road_label" size="13" priority="10"/>
        </m>
    </m>
    <m e="way" k="highway" v="secondary|secondary_link">
        <m zoom-min="13">
            <line stroke="#ffffff" cap="round" width="1.7"/>
        </m>
        <m zoom-max="12" zoom-min="10">
            <line stroke="#ffffff" cap="round" width="1.5"/>
        </m>
        <m zoom-min="10">
            <text use="road_label" size="13" priority="11"/>
        </m>
    </m>
    <m e="way" k="highway" v="primary|primary_link">
        <m zoom-min="12">
            <line stroke="#ffffff" cap="round" width="1.9"/>
        </m>
        <m zoom-max="11" zoom-min="8">
            <line stroke="#ffffff" cap="round" width="1.7"/>
        </m>
        <m zoom-min="8">
            <text use="road_label" size="13" priority="12"/>
        </m>
    </m>
    
    <!-- path - allows bicycles by default. Yellow dash indicates mountain bike preferred, white dash -->
    <!--     indicates bicycle access but no special mountain bike information -->
    <m e="way" k="highway" v="path">
        <m select="first">
            <m k="cycleway" v="*">
                <line use="cycling_path"/>
            </m>
            <m k="bicycle" v="yes|designated">
                <line use="cycling_path"/>
            </m>
            <m k="surface" v="fine_gravel">
                <line use="track_chasing"/>
                <line use="track"/>
            </m>
            <m k="~" v="~">
                <line use="path"/>
            </m>
        </m>
        <m zoom-min="14">
            <text use="road_label" size="13" priority="7"/>
        </m>
    </m>

    <m e="way" k="highway" v="path">
        <m select="first">
            <m e="way" k="mtb:scale" v="0" zoom-min="12">
                <line use="MTB_0_chasing"/>
                <line use="MTB_path"/>
            </m>
    <!-- S1 - Lime -->
            <m e="way" k="mtb:scale" v="1|1+" zoom-min="12">
                <line use="MTB_1_chasing"/>
                <line use="MTB_path"/>
            </m>
    <!-- S2 - Yellow -->
            <m e="way" k="mtb:scale" v="2" zoom-min="12">
                <line use="MTB_2_chasing"/>
                <line use="MTB_path"/>
            </m>
    <!-- S3 - Orange -->
            <m e="way" k="mtb:scale" v="3" zoom-min="12">
                <line use="MTB_3_chasing"/>
                <line use="MTB_path"/>
            </m>
    <!-- S4+ - Red: Extreme -->
            <m e="way" k="mtb:scale" v="4" zoom-min="12">
                <line use="MTB_4_chasing"/>
                <line use="MTB_path"/>
            </m>
            <m e="way" k="mtb:scale" v="5" zoom-min="12">
                <line use="MTB_5_chasing"/>
                <line use="MTB_path"/>
            </m>
        </m>
    </m>

    <m e="way" k="highway" v="track">
        <line use="track_chasing"/>
        <line use="track"/>
    </m>

    <!-- highway=cycleway indicates a separate way used for cycling -->
    <m e="way" k="highway" v="cycleway">
        <line use="cycling_path"/>
        <m zoom-min="13">
            <text use="road_label" fill="#222222" size="14" priority="6"/>
        </m>
    </m>

    <!-- route=ferry -->
    <m e="way" k="route" v="ferry">
        <line use="ferry"/>
        <m zoom-min="12">
            <text use="road_label" fill="#222222" size="13" priority="9"/>
        </m>
    </m>

    <!-- highway one-way markers -->
    <m k="tunnel" v="~|false|no">
        <m k="area" v="~|false|no">
            <m k="highway">
                <m k="oneway" v="yes|true" zoom-min="15">
                    <lineSymbol src="file:/icons/oneway.svg" symbol-percent="125" repeat-gap="175"/>
                </m>
            </m>
        </m>
    </m>

    <!-- /roads -->

    <!-- poi -->
    <m e="node" k="amenity">
        <m v="bank|atm" zoom-min="15">
            <symbol id="bank" symbol-percent="125" src="file:/icons/bank-15-bg.svg"/>
        </m>
        <m v="beach" zoom-min="15">
            <symbol id="beach" symbol-percent="125" src="file:/icons/beach-15-bg.svg"/>
        </m>
        <m v="grave_yard" zoom-min="15">
            <symbol id="cemetery" symbol-percent="125" src="file:/icons/cemetery-15-bg.svg"/>
        </m>
        <m v="university" zoom-min="15">
            <symbol id="college" symbol-percent="125" src="file:/icons/college-15-bg.svg"/>
        </m>
        <m v="convenience" zoom-min="15">
            <symbol id="convenience" symbol-percent="125" src="file:/icons/convenience-15-bg.svg"/>
        </m>
        <m v="hospital" zoom-min="15">
            <symbol id="hospital" symbol-percent="125" src="file:/icons/hospital-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <m e="node" k="tourism" v="information" zoom-min="15">
            <symbol id="information" symbol-percent="125" src="file:/icons/information-15-bg.svg"/>
        </m>
        <m v="library" zoom-min="15">
            <symbol id="library" symbol-percent="125" src="file:/icons/library-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <!-- <m e="node" k="amenity" v="park" zoom-min="15">
            <symbol id="park" symbol-percent="125" src="file:/icons/park-15-bg.svg" />
        </m> -->
        <!-- <m e="node" k="amenity" v="parking" zoom-min="13">
            <symbol id="parking" symbol-percent="125" src="file:/icons/parking-15-bg.svg" />
        </m> -->
        <m v="pharmacy" zoom-min="15">
            <symbol id="pharmacy" symbol-percent="125" src="file:/icons/pharmacy-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <m v="police" zoom-min="15">
            <symbol id="police" symbol-percent="125" src="file:/icons/police-15-bg.svg"/>
        </m>
        <m v="toilets" zoom-min="15">
            <symbol id="toilet" symbol-percent="125" src="file:/icons/toilet-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <m v="drinking_water" zoom-min="15">
            <symbol id="drinking-water" symbol-percent="125" src="file:/icons/drinking-water-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <m v="cafe" zoom-min="15">
            <symbol id="cafe" symbol-percent="125" src="file:/icons/cafe-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
        <m v="bicycle_rental" zoom-min="15">
            <symbol id="bicycle" symbol-percent="125" src="file:/icons/bicycle-15-bg.svg"/>
        </m>
    </m>
    <m e="node" k="tourism">
        <m v="picnic_site" zoom-min="15">
            <symbol id="picnic-site" symbol-percent="125" src="file:/icons/picnic-site-15-bg.svg"/>
        </m>
        <m v="camp_site" zoom-min="15">
            <symbol id="campsite" symbol-percent="125" src="file:/icons/campsite-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
    </m>
    <m e="node" k="shop">
        <m v="supermarket" zoom-min="15">
            <symbol id="grocery" symbol-percent="125" src="file:/icons/grocery-15-bg.svg"/>
        </m>
        <m v="bicycle" zoom-min="15">
            <symbol id="bicycle" symbol-percent="125" src="file:/icons/bicycle-15-bg.svg"/>
            <text use="poi_label"/>
        </m>
    </m>

    <!-- place labels -->
    <m e="node" k="place">
        <m v="locality" zoom-min="13">
            <caption style="bold" fill="#606060" k="name" priority="5" size="13"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
        <m v="suburb|neighborhood" zoom-min="12">
            <caption style="bold_italic" fill="#404040" k="name" priority="4" size="14"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
        <m v="village|hamlet" zoom-min="12">
            <caption style="bold_italic" fill="#404040" k="name" priority="3" size="15"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
        <m v="island" zoom-min="10">
            <caption style="bold_italic" fill="#404040" k="name" priority="5" size="15"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
        <m v="town">
            <caption style="bold_italic" fill="#404040" k="name" priority="2" size="16"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
        <m v="city">
            <caption style="bold_italic" dy="14" fill="#000000" k="name" priority="1" size="17"
                    font-family="thin" stroke="#ffffff" stroke-width="2.0" />
        </m>
    </m>
    <!-- /place -->

</rendertheme>
'@ -Encoding UTF8

    Add-Log "  Theme file restored to data\offline_v15.xml"
}

# ============================================================
# ENSURE ICON ASSETS
# ============================================================

function Ensure-IconAssets {
    $iconsDir = Join-Path $ScriptDir 'data\icons'
    $svgFile = Join-Path $iconsDir 'bare_rock.svg'

    if (Test-Path $svgFile) {
        Add-Log '  Icon assets: data\icons\'
        return
    }

    Add-Log '  Icon assets not found. Restoring bare_rock.svg from embedded copy...'
    if (-not (Test-Path $iconsDir)) {
        New-Item -ItemType Directory -Path $iconsDir -Force | Out-Null
    }

    $svgContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <!-- Bare rock/bedrock pattern - small scattered rock fragments -->
  <!-- Transparent background so it layers over the area fill -->
  <g fill="#8b7355" fill-opacity="0.6" stroke="none">
    <!-- Row 1 -->
    <ellipse cx="8" cy="6" rx="3" ry="2"/>
    <ellipse cx="28" cy="4" rx="2.5" ry="1.8"/>
    <ellipse cx="50" cy="8" rx="2" ry="1.5"/>
    <!-- Row 2 -->
    <ellipse cx="18" cy="18" rx="2.5" ry="1.8"/>
    <ellipse cx="42" cy="16" rx="3" ry="2"/>
    <!-- Row 3 -->
    <ellipse cx="4" cy="30" rx="2" ry="1.5"/>
    <ellipse cx="24" cy="28" rx="3.5" ry="2.2"/>
    <ellipse cx="54" cy="32" rx="2.5" ry="1.8"/>
    <!-- Row 4 -->
    <ellipse cx="12" cy="42" rx="2.5" ry="2"/>
    <ellipse cx="38" cy="40" rx="2" ry="1.5"/>
    <!-- Row 5 -->
    <ellipse cx="8" cy="54" rx="3" ry="2"/>
    <ellipse cx="30" cy="52" rx="2.5" ry="1.8"/>
    <ellipse cx="52" cy="56" rx="2" ry="1.5"/>
    <!-- Scattered small dots -->
    <circle cx="58" cy="20" r="1.2"/>
    <circle cx="14" cy="10" r="1"/>
    <circle cx="34" cy="46" r="1.3"/>
    <circle cx="46" cy="48" r="1"/>
    <circle cx="20" cy="56" r="1.1"/>
    <circle cx="56" cy="44" r="0.9"/>
  </g>
</svg>
'@
    Set-Content -Path $svgFile -Value $svgContent -Encoding UTF8
    Add-Log '  Restored icon asset: data\icons\bare_rock.svg'
}

# ============================================================
# PREREQUISITE CHECKS
# ============================================================

# Eclipse Temurin JRE 17 portable download URL (Windows x64 ZIP)
# Uses JRE instead of full JDK — saves ~140 MB download (42 MB vs 181 MB)
$Jre17Url = 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jre/hotspot/normal/eclipse?project=jdk'

# Maven Central pre-built mapsforge-map-writer JAR (with dependencies)
# Eliminates need to download source + run Gradle build (saves ~150 MB + minutes of build time)
$MapwriterJarUrl = 'https://repo1.maven.org/maven2/org/mapsforge/mapsforge-map-writer/0.20.0/mapsforge-map-writer-0.20.0-jar-with-dependencies.jar'

function Test-Java {
    # 1. Check bundled JRE in build-tools first
    $bundledJre = Join-Path $BuildDir 'jre-17\bin\java.exe'
    if (Test-Path $bundledJre) {
        Add-Log "  [OK] Using bundled JRE 17: $bundledJre"
        return $bundledJre
    }

    # 2. Check JAVA_HOME
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if (-not $javaHome) { $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User') }
    if ($javaHome) {
        $candidate = Join-Path $javaHome 'bin\java.exe'
        if (Test-Path $candidate) {
            $ver = Get-JavaVersion $candidate
            if ($ver -ge 17) { return $candidate }
        }
    }

    # 3. Check PATH
    try {
        $exe = (Get-Command 'java.exe' -ErrorAction Stop).Source
        $ver = Get-JavaVersion $exe
        if ($ver -ge 17) { return $exe }
    } catch { }

    # 4. No suitable Java found — will offer to download bundled JRE
    return $null
}

function Get-JavaVersion {
    param([string]$JavaExe)
    try {
        $output = & $JavaExe -version 2>&1 | Out-String
        $match = [regex]::Match($output, '"(\d+)(\.\d+)*"')
        if ($match.Success) {
            return [int]$match.Groups[1].Value
        }
        # Handle old-style version strings like "1.8.0_491"
        $match = [regex]::Match($output, '"1\.(\d+)')
        if ($match.Success) {
            return [int]$match.Groups[1].Value
        }
    } catch { }
    return 0
}

function Install-BundledJre {
    <#
    .SYNOPSIS
        Download and extract Eclipse Temurin JRE 17 portable ZIP to build-tools\jre-17.
        Uses JRE instead of full JDK — saves ~140 MB download (42 MB vs 181 MB).
    #>
    $jreDir = Join-Path $BuildDir 'jre-17'
    $jreExe = Join-Path $jreDir 'bin\java.exe'
    $jreZip = Join-Path $BuildDir 'jre-17.zip'

    # Already installed?
    if (Test-Path $jreExe) {
        Add-Log "  Bundled JRE 17 already installed: $jreDir"
        return $jreExe
    }

    Add-Log ''
    Add-Log '=== Java 17+ not found. Downloading bundled JRE 17... ==='
    Set-Status 'Downloading JRE 17...'

    # Download
    if (-not (Test-Path $jreZip)) {
        Add-Log "  Downloading from Adoptium (Eclipse Temurin JRE)..."
        try {
            Invoke-FastDownload -Url $Jre17Url -OutFile $jreZip
        } catch {
            Add-Log "  ERROR: Failed to download JRE 17: $_"
            Add-Log '  Please install Java 17+ manually and set JAVA_HOME.'
            return $null
        }
    } else {
        Add-Log "  Using cached JRE archive: $jreZip"
    }

    # Extract
    Add-Log '  Extracting JRE...'
    Set-Status 'Extracting JRE 17...'
    try {
        $tempDir = Join-Path $BuildDir 'jre-extract-temp'
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
        Expand-Archive -Path $jreZip -DestinationPath $tempDir -Force

        # The ZIP contains a folder like "jdk-17.0.19+10-jre" — find it and rename
        $extractedFolder = Get-ChildItem -Path $tempDir -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'bin\java.exe')
        } | Select-Object -First 1

        if ($extractedFolder) {
            if (Test-Path $jreDir) { Remove-Item $jreDir -Recurse -Force }
            Move-Item $extractedFolder.FullName $jreDir -Force
            Add-Log "  JRE 17 installed to: $jreDir"
        } else {
            Add-Log '  ERROR: Could not find java.exe in extracted JRE archive.'
            return $null
        }

        # Clean up temp dir
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        # Remove ZIP after successful extraction
        if (Test-Path $jreZip) { Remove-Item $jreZip -Force -ErrorAction SilentlyContinue }
    } catch {
        Add-Log "  ERROR: Failed to extract JRE: $_"
        return $null
    }

    # Verify
    if (Test-Path $jreExe) {
        $ver = Get-JavaVersion $jreExe
        Add-Log "  [OK] Bundled JRE 17 verified (version: $ver)"
        return $jreExe
    } else {
        Add-Log '  ERROR: Bundled JRE java.exe not found after extraction.'
        return $null
    }
}

function Test-Adb {
    # 1. Check bundled ADB in build-tools first
    $bundledAdb = Join-Path $BuildDir 'platform-tools\adb.exe'
    if (Test-Path $bundledAdb) {
        Add-Log "  [OK] Using bundled ADB: $bundledAdb"
        return $bundledAdb
    }

    # 2. Check PATH
    try {
        $exe = (Get-Command 'adb.exe' -ErrorAction Stop).Source
        return $exe
    } catch {
        try {
            $exe = (Get-Command 'adb' -ErrorAction Stop).Source
            return $exe
        } catch {
            # 3. Check common Android SDK locations
            $candidates = @(
                "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
                "$env:ProgramFiles\Android\platform-tools\adb.exe"
                "${env:ProgramFiles(x86)}\Android\platform-tools\adb.exe"
                "C:\Android\platform-tools\adb.exe"
            )
            foreach ($c in $candidates) {
                if (Test-Path $c) { return $c }
            }
            return $null
        }
    }
}

function Install-BundledAdb {
    <#
    .SYNOPSIS
        Download and extract Android SDK Platform Tools (adb.exe) to build-tools\platform-tools.
        Makes the app fully self-contained — no separate ADB install needed for push.
    #>
    $adbExe = Join-Path $BuildDir 'platform-tools\adb.exe'

    # Already installed?
    if (Test-Path $adbExe) {
        Add-Log "  Bundled ADB already installed: $(Join-Path $BuildDir 'platform-tools')"
        return $adbExe
    }

    Add-Log ''
    Add-Log '=== ADB not found. Downloading Android Platform Tools... ==='
    Set-Status 'Downloading ADB...'

    $zipFile = Join-Path $BuildDir 'platform-tools.zip'

    # Download
    if (-not (Test-Path $zipFile)) {
        Add-Log "  Downloading from Google..."
        try {
            Invoke-FastDownload -Url 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zipFile
        } catch {
            Add-Log "  ERROR: Failed to download ADB: $_"
            Add-Log '  Install Android SDK Platform Tools manually and add to PATH.'
            return $null
        }
    } else {
        Add-Log "  Using cached ADB archive: $zipFile"
    }

    # Extract — the ZIP contains a 'platform-tools' folder directly
    Add-Log '  Extracting ADB...'
    Set-Status 'Extracting ADB...'
    try {
        $tempDir = Join-Path $BuildDir 'adb-extract-temp'
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
        Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

        # Move platform-tools folder into build-tools
        $extractedDir = Join-Path $tempDir 'platform-tools'
        if (Test-Path $extractedDir) {
            $targetDir = Join-Path $BuildDir 'platform-tools'
            if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
            Move-Item $extractedDir $targetDir -Force
            Add-Log "  ADB installed to: $targetDir"
        } else {
            Add-Log '  ERROR: Could not find platform-tools in extracted archive.'
            return $null
        }

        # Clean up temp dir
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        # Remove ZIP after successful extraction
        if (Test-Path $zipFile) { Remove-Item $zipFile -Force -ErrorAction SilentlyContinue }
    } catch {
        Add-Log "  ERROR: Failed to extract ADB: $_"
        return $null
    }

    # Verify
    if (Test-Path $adbExe) {
        Add-Log '  [OK] Bundled ADB verified'
        return $adbExe
    } else {
        Add-Log '  ERROR: Bundled adb.exe not found after extraction.'
        return $null
    }
}

# ============================================================
# PROCESS RUNNER (streaming output in real-time, with UI pump)
# Uses Register-ObjectEvent + BeginOutputReadLine to capture tool
# output line-by-line. Polls Get-Event during WaitForExit loops
# so log output appears in real-time and the UI stays responsive.
# Shows elapsed time in the status bar while the process runs.
# ============================================================
function Invoke-Process {
    param(
        [string]$FileName,
        [string]$Arguments,
        [string]$WorkingDirectory = '',
        [int]$TimeoutMs = 0,
        [string]$StatusPrefix = ''
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # Unique source identifiers to avoid collisions if called multiple times
    $evtId = Get-Random
    $outSrc = "ProcOut_$evtId"
    $errSrc = "ProcErr_$evtId"

    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier $outSrc | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier $errSrc | Out-Null

    $null = $proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    # Helper: drain queued PS events into the log
    $drainEvents = {
        foreach ($ev in (Get-Event -SourceIdentifier $outSrc -ErrorAction SilentlyContinue)) {
            if ($ev.SourceEventArgs.Data) { Add-Log "  $($ev.SourceEventArgs.Data)" }
            Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
        }
        foreach ($ev in (Get-Event -SourceIdentifier $errSrc -ErrorAction SilentlyContinue)) {
            if ($ev.SourceEventArgs.Data) { Add-Log "  $($ev.SourceEventArgs.Data)" }
            Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
        }
    }

    # Wait for process to exit, draining events and updating status with elapsed time
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatusUpdate = [datetime]::MinValue

    while (-not $proc.WaitForExit(200)) {
        . $drainEvents
        [System.Windows.Forms.Application]::DoEvents()
        # Update status bar with elapsed time every second
        if (([datetime]::Now - $lastStatusUpdate).TotalSeconds -ge 1) {
            $elapsed = $sw.Elapsed
            $elapsedStr = "$([math]::Floor($elapsed.TotalMinutes)):$($elapsed.Seconds.ToString('00'))"
            if ($StatusPrefix) {
                Set-Status "$StatusPrefix ($elapsedStr)"
            }
            $lastStatusUpdate = [datetime]::Now
        }
        if ($TimeoutMs -gt 0 -and $sw.ElapsedMilliseconds -gt $TimeoutMs) {
            Add-Log '  Process timed out, killing...'
            $proc.Kill()
            break
        }
    }

    # Final drain: events may arrive after process exits
    Start-Sleep -Milliseconds 200
    . $drainEvents
    [System.Windows.Forms.Application]::DoEvents()

    # Report total elapsed time
    $totalElapsed = "$([math]::Floor($sw.Elapsed.TotalMinutes)):$($sw.Elapsed.Seconds.ToString('00'))"
    if ($StatusPrefix) { Add-Log "  Completed in $totalElapsed" }

    # Clean up event registrations
    Unregister-Event -SourceIdentifier $outSrc -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $errSrc -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $outSrc -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $errSrc -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue

    return $proc.ExitCode
}

# ============================================================
# BUILD PIPELINE
# ============================================================
function Invoke-BuildPipeline {
    param([string]$DisplayName)

    $regionInfo = $RegionData[$DisplayName]
    $key = $regionInfo.Key
    $pbfUrl = $regionInfo.Url
    $bbox = $regionInfo.Bbox
    $startPos = $regionInfo.Start

    $inputPbf = Join-Path $BuildDir "$key-latest.osm.pbf"
    $filteredPbf = Join-Path $BuildDir "$key-mtb-scale-only.osm.pbf"
    $outputMap = Join-Path $ScriptDir "data\$key-mtb-overlay.map"
    $osmosisDir = Join-Path $BuildDir 'osmosis'
    $osmosisBat = Join-Path $osmosisDir 'bin\osmosis.bat'
    $mapwriterJar = Join-Path $BuildDir 'mapsforge-map-writer.jar'
    $tagMappingMerged = Join-Path $BuildDir 'tag-mapping-mtb-merged.xml'

    # Set JAVA_HOME for Osmosis (needs to find java.exe)
    $savedJavaHome = $env:JAVA_HOME
    if ($script:JavaPath) {
        $javaHomeDir = Split-Path (Split-Path $script:JavaPath)
        $env:JAVA_HOME = $javaHomeDir
        Add-Log "  JAVA_HOME set to $javaHomeDir"
    }

    # Ensure data directory exists
    $dataDir = Join-Path $ScriptDir 'data'
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    # ----------------------------------------------------------
    # 1. Setup Osmosis + mapsforge-map-writer
    # ----------------------------------------------------------
    Add-Log "=== Step 1/5: Setting up Osmosis + Mapsforge map-writer ==="

    if (-not (Test-Path (Join-Path $osmosisDir 'bin\osmosis.bat'))) {
        Add-Log 'Setting up Osmosis...'

        $zipFile = Join-Path $BuildDir "osmosis-$OsmosisVer.zip"
        if (-not (Test-Path $zipFile)) {
            $osmosisUrl = "https://github.com/openstreetmap/osmosis/releases/download/$OsmosisVer/osmosis-$OsmosisVer.zip"
            Add-Log "  Downloading Osmosis $OsmosisVer ..."
            Set-Status 'Downloading Osmosis...'
            try {
                Invoke-FastDownload -Url $osmosisUrl -OutFile $zipFile
            } catch {
                Add-Log "  ERROR: Failed to download Osmosis: $_"
                throw "Download failed: $_"
            }
        }

        Add-Log '  Extracting Osmosis...'
        Set-Status 'Extracting Osmosis...'
        Expand-Archive -Path $zipFile -DestinationPath $osmosisDir -Force
        Add-Log "  Extracted to: $osmosisDir"
        # Remove ZIP after successful extraction
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    } else {
        Add-Log "  [OK] Osmosis found at $osmosisDir"
    }

    # Download pre-built mapsforge-map-writer JAR from Maven Central
    # (eliminates ~150 MB source download + multi-minute Gradle build)
    if (-not (Test-Path $mapwriterJar)) {
        Add-Log 'Downloading mapsforge-map-writer JAR...'
        Set-Status 'Downloading map-writer JAR...'
        try {
            Invoke-FastDownload -Url $MapwriterJarUrl -OutFile $mapwriterJar
        } catch {
            Add-Log "  ERROR: Failed to download map-writer JAR: $_"
            throw "Download failed: $_"
        }
        $jarSize = (Get-Item $mapwriterJar).Length
        Add-Log "  Map-writer JAR: $mapwriterJar ($(Format-FileSize $jarSize))"
    } else {
        Add-Log "  [OK] Mapsforge map-writer JAR found at $mapwriterJar"
    }

    # Install JAR into Osmosis lib
    $osmosisLibDir = Join-Path $osmosisDir 'lib\default'
    if (-not (Test-Path $osmosisLibDir)) { New-Item -ItemType Directory -Path $osmosisLibDir -Force | Out-Null }
    Copy-Item -Path $mapwriterJar -Destination $osmosisLibDir -Force
    Add-Log "  Map-writer JAR installed into Osmosis lib"
    Add-Log "  [OK] Step 1/5 complete"

    # ----------------------------------------------------------
    # 2. Generate merged tag-mapping
    # ----------------------------------------------------------
    Add-Log ''
    Add-Log "=== Step 2/5: Generating merged tag-mapping ==="

    # Regenerate merged tag-mapping if missing or stale (lacks dedup)
    $needsMerge = -not (Test-Path $tagMappingMerged)
    if (-not $needsMerge) {
        $existingContent = Get-Content -Path $tagMappingMerged -Raw -ErrorAction SilentlyContinue
        if ($existingContent -notmatch 'mtb-overlay-builder-dedup-v2') { $needsMerge = $true }
    }

    if ($needsMerge) {
        $defaultMapping = Join-Path $BuildDir 'tag-mapping-default.xml'
        if (-not (Test-Path $defaultMapping)) {
            $mappingUrl = 'https://raw.githubusercontent.com/mapsforge/mapsforge/master/mapsforge-map-writer/src/main/config/tag-mapping.xml'
            Add-Log '  Downloading default tag-mapping...'
            Set-Status 'Downloading tag-mapping...'
            try {
                Invoke-FastDownload -Url $mappingUrl -OutFile $defaultMapping
            } catch {
                Add-Log "  ERROR: Failed to download tag-mapping: $_"
                throw "Download failed: $_"
            }
        }

        Add-Log '  Merging MTB scale tags...'
        $content = Get-Content -Path $defaultMapping -Raw

        # Remove any existing MTB tags from the default mapping to avoid duplicates
        $content = $content -replace '(?m)^\s*<osm-tag\s+key="mtb:scale[^/]*/>\s*\r?\n', ''

        $mtbTags = @'
        <!-- MTB SCALE (added by mtb-overlay-builder) -->
        <osm-tag key="mtb:scale" value="0" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="1" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="2" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="3" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="4" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="5" zoom-appear="12"/>
        <osm-tag key="mtb:scale" value="6" zoom-appear="12"/>
        <osm-tag key="mtb:scale:uphill" value="0" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:uphill" value="1" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:uphill" value="2" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:uphill" value="3" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:uphill" value="4" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:uphill" value="5" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:imba" value="0" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:imba" value="1" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:imba" value="2" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:imba" value="3" zoom-appear="12" renderable="false"/>
        <osm-tag key="mtb:scale:imba" value="4" zoom-appear="12" renderable="false"/>
        <osm-tag key="natural" value="bare_rock" zoom-appear="12"/>
'@
        $content = $content -replace '</ways>', "$mtbTags`n        </ways>"
        # Add version marker so we can detect stale merged files
        $content = $content -replace '<osm-map-tag-mapping', "<osm-map-tag-mapping`n  <!-- mtb-overlay-builder-dedup-v2 -->"
        Set-Content -Path $tagMappingMerged -Value $content -Encoding UTF8
        Add-Log "  Merged tag-mapping: $tagMappingMerged"
    } else {
        Add-Log "  [OK] Merged tag-mapping found at $tagMappingMerged"
    }
    Add-Log "  [OK] Step 2/5 complete"

    # ----------------------------------------------------------
    # 3. Download PBF
    # ----------------------------------------------------------
    Add-Log ''
    Add-Log "=== Step 3/5: Downloading OSM data for $DisplayName ==="

    if (-not (Test-Path $inputPbf)) {
        try {
            Invoke-FastDownload -Url $pbfUrl -OutFile $inputPbf
        } catch {
            Add-Log "  ERROR: Failed to download OSM data: $_"
            throw "Download failed: $_"
        }
    } else {
        $size = (Get-Item $inputPbf).Length
        $sizeStr = Format-FileSize $size
        Add-Log "  Using cached: $inputPbf ($sizeStr)"
    }
    Add-Log "  [OK] Step 3/5 complete"

    # ----------------------------------------------------------
    # 4. Filter to mtb:scale ways and bare_rock areas
    # ----------------------------------------------------------
    Add-Log ''
    Add-Log '=== Step 4/5: Filtering to mtb:scale ways and bare_rock areas ==='

    if ((Test-Path $filteredPbf) -and ((Get-Item $filteredPbf).LastWriteTime -gt (Get-Item $inputPbf).LastWriteTime)) {
        $size = (Get-Item $filteredPbf).Length
        $sizeStr = Format-FileSize $size
        Add-Log "  [OK] Using cached filtered data: $filteredPbf ($sizeStr)"
    } else {
        Add-Log '  Running Osmosis filter...'
        Set-Status 'Filtering OSM data...'
        $exitCode = Invoke-Process -FileName $osmosisBat -Arguments "--rb file=`"$inputPbf`" --tf accept-ways mtb:scale=* natural=bare_rock --used-node --wb file=`"$filteredPbf`" omitmetadata=true" -TimeoutMs 600000 -StatusPrefix 'Filtering OSM data...'
        if ($exitCode -ne 0) {
            Add-Log "  ERROR: Osmosis filter failed with exit code $exitCode"
            throw "Osmosis filter failed"
        }
        if (Test-Path $filteredPbf) {
            $size = (Get-Item $filteredPbf).Length
            $sizeStr = Format-FileSize $size
            Add-Log "  Filtered: $filteredPbf ($sizeStr)"
        }
    }
    Add-Log "  [OK] Step 4/5 complete"

    # ----------------------------------------------------------
    # 5. Build Mapsforge map
    # ----------------------------------------------------------
    Add-Log ''
    Add-Log "=== Step 5/5: Building Mapsforge .map file ==="

    $bboxParts = $bbox -split ','
    $bottom = $bboxParts[0]
    $left = $bboxParts[1]
    $top = $bboxParts[2]
    $right = $bboxParts[3]

    $startParts = $startPos -split ','
    $startLat = $startParts[0]
    $startLon = $startParts[1]

    $cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if (-not $cpuCount -or $cpuCount -lt 1) { $cpuCount = 4 }

    Add-Log "  Output: $outputMap"
    Add-Log "  Bbox: $bbox"
    Add-Log "  Start: $startPos"
    Add-Log "  Threads: $cpuCount"

    Set-Status 'Building map...'
    # Set JVM heap for type=ram (needs ~10x filtered PBF size in memory;
    # 1 GB is plenty for typical filtered MTB data of 10-20 MB)
    $oldJavacmdOpts = $env:JAVACMD_OPTIONS
    $env:JAVACMD_OPTIONS = '-Xmx2g'
    $osmosisArgs = "--rb file=`"$filteredPbf`" --mw file=`"$outputMap`" bbox=$bottom,$left,$top,$right map-start-position=$startLat,$startLon map-start-zoom=10 tag-values=false type=ram preferred-languages=en,fi threads=$cpuCount tag-conf-file=`"$tagMappingMerged`" progress-logs=true zoom-interval-conf=5,0,7,10,8,11,14,12,21"
    $exitCode = Invoke-Process -FileName $osmosisBat -Arguments $osmosisArgs -TimeoutMs 600000 -StatusPrefix 'Building map...'
    $env:JAVACMD_OPTIONS = $oldJavacmdOpts

    if ($exitCode -ne 0) {
        Add-Log "  ERROR: Osmosis map build failed with exit code $exitCode"
        throw "Osmosis map build failed"
    }

    if (Test-Path $outputMap) {
        $size = (Get-Item $outputMap).Length
        $sizeStr = Format-FileSize $size
        Add-Log "  Map file created: $outputMap ($sizeStr)"
    }
    Add-Log "  [OK] Step 5/5 complete"

    # Verify theme XML exists in data/
    $themeInData = Join-Path $dataDir 'offline_v15.xml'
    if (Test-Path $themeInData) {
        Add-Log '  Theme: offline_v15.xml in data/'
    }

    Add-Log ''
    Add-Log '=== Build complete! ==='
    Add-Log "Output: $outputMap"
    Add-Log ''
    Add-Log 'To use on Karoo:'
    Add-Log '  1. Click "Push to Karoo" to push via ADB'
    Add-Log '  2. Or copy files from data/ to the Karoo'
    Add-Log '  3. Add as overlay map in the Karoo map settings'
}

# ============================================================
# PUSH PIPELINE
# ============================================================
function Invoke-PushPipeline {
    param([string]$DisplayName)

    $regionInfo = $RegionData[$DisplayName]
    $key = $regionInfo.Key
    $mapFile = Join-Path $ScriptDir "data\$key-mtb-overlay.map"

    # Ensure data directory exists for push
    $dataDir = Join-Path $ScriptDir 'data'
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    if (-not (Test-Path $mapFile)) {
        Add-Log "ERROR: Map file not found: $mapFile"
        Add-Log 'Build the map first, then try pushing.'
        throw "Map file not found: $mapFile"
    }

    Add-Log "=== Pushing $key overlay map to Karoo ==="
    Add-Log "Map file: $mapFile"

    # 1. Find ADB
    $adb = Test-Adb
    if (-not $adb) {
        Add-Log 'ERROR: adb not found.'
        Add-Log 'Install Android SDK Platform Tools:'
        Add-Log '  https://developer.android.com/tools/releases/platform-tools'
        throw 'ADB not found'
    }
    Add-Log "Using ADB: $adb"

    # 2. Check for connected device
    Set-Status 'Checking ADB devices...'
    Add-Log 'Checking for connected devices...'
    $devicesOutput = & $adb devices 2>&1
    $deviceLines = $devicesOutput | Where-Object { $_ -match 'device$' -and $_ -notmatch 'List of devices' }
    $deviceCount = ($deviceLines | Measure-Object).Count

    if ($deviceCount -eq 0) {
        Add-Log 'ERROR: No Android device detected.'
        Add-Log ''
        Add-Log 'Make sure:'
        Add-Log '  1. Karoo is connected via USB'
        Add-Log '  2. USB Debugging is enabled (Settings -> Developer Options)'
        Add-Log '  3. RSA authorization prompt is accepted on the Karoo'
        Add-Log "  4. Try: $adb kill-server && $adb start-server"
        throw 'No device detected'
    }

    if ($deviceCount -gt 1) {
        Add-Log 'ERROR: Multiple Android devices detected. Connect only the Karoo.'
        throw 'Multiple devices detected'
    }

    Add-Log "  Found $deviceCount device(s)"

    # 3. Detect Karoo storage path
    Set-Status 'Detecting Karoo paths...'
    Add-Log 'Detecting Karoo storage paths...'
    $mapsPath = $null
    $themeBase = $null
    $candidates = @('/sdcard/offline/maps', '/mnt/sdcard/offline/maps', '/storage/emulated/0/offline/maps')
    foreach ($p in $candidates) {
        $result = & $adb shell "ls $p/" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $mapsPath = $p
            Add-Log "  Found maps path: $mapsPath"
            break
        }
    }
    if (-not $mapsPath) {
        $mapsPath = '/sdcard/offline/maps'
        Add-Log "  Using default maps path: $mapsPath"
    }

    # Detect theme base path and actual offline_v*.xml filename on device
    $themeBase = $null
    $themeFilename = 'offline_v15.xml'  # default fallback
    $themeCandidates = @('/sdcard', '/mnt/sdcard', '/storage/emulated/0')
    foreach ($p in $themeCandidates) {
        $result = & $adb shell "ls ${p}/offline_v*.xml" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $themeBase = $p
            # Extract the actual filename from the ls output
            $matched = $result | Where-Object { $_ -match 'offline_v\d+\.xml' } | Select-Object -First 1
            if ($matched) {
                $themeFilename = ($matched -split '/')[-1].Trim()
            }
            Add-Log "  Found theme: ${themeBase}/${themeFilename}"
            break
        }
    }
    if (-not $themeBase) {
        $themeBase = '/sdcard'
        Add-Log "  Using default theme base: $themeBase (theme filename: $themeFilename)"
    }

    # 4. Ensure target directory exists
    & $adb shell "mkdir -p $mapsPath" 2>&1 | Out-Null

    # 5. Push map file
    Set-Status 'Pushing map to Karoo...'
    Add-Log "Pushing map to $mapsPath ..."
    $pushResult = & $adb push $mapFile "$mapsPath/$key-mtb-overlay.map" 2>&1
    Add-Log "  $pushResult"
    if ($LASTEXITCODE -ne 0) {
        Add-Log 'ERROR: Failed to push map file.'
        throw 'Map push failed'
    }
    Add-Log 'Map file pushed successfully.'

    # 6. Push theme if available
    $themeFile = Join-Path $ScriptDir 'data\offline_v15.xml'
    if (Test-Path $themeFile) {
        Add-Log 'Pushing theme file...'
        Set-Status 'Pushing theme...'
        # Backup existing theme
        $bakResult = & $adb shell "cp ${themeBase}/${themeFilename} ${themeBase}/${themeFilename}.bak" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Add-Log "  Backed up existing theme: ${themeBase}/${themeFilename}.bak"
        } else {
            Add-Log "  NOTE: Could not back up existing theme (may not exist yet): $bakResult"
        }
        $pushResult = & $adb push $themeFile "${themeBase}/${themeFilename}" 2>&1
        Add-Log "  $pushResult"
        if ($LASTEXITCODE -ne 0) {
            Add-Log '  WARNING: Failed to push theme file.'
        } else {
            Add-Log 'Theme file pushed successfully.'
        }
    } else {
        Add-Log "NOTE: No offline_v15.xml found in data/ folder. Place the theme file there to push it (will be pushed as ${themeFilename} on device)."
    }

    # 7. Push icon/pattern assets if available
    $iconsDir = Join-Path $ScriptDir 'data\icons'
    if (Test-Path $iconsDir) {
        Add-Log 'Pushing icon assets...'
        Set-Status 'Pushing icons...'
        & $adb shell "mkdir -p ${themeBase}/icons" 2>&1 | Out-Null
        $iconFiles = Get-ChildItem -Path $iconsDir -File
        foreach ($iconFile in $iconFiles) {
            $pushResult = & $adb push $iconFile.FullName "${themeBase}/icons/" 2>&1
            Add-Log "  Pushed: $($iconFile.Name)"
        }
        Add-Log 'Icon assets pushed successfully.'
    }

    Add-Log ''
    Add-Log '=== Push complete! ==='
    Add-Log ''
    Add-Log 'Please restart the Karoo to reload map data.'
    Add-Log '  Hold power button -> Restart, or run: adb reboot'
}

# ============================================================
# BUILD UI
# ============================================================
function Build-UI {
    $script:form = New-Object System.Windows.Forms.Form
    $form.Text = 'MTB Trail Overlay Map Builder v1.0'
    $form.Size = New-Object System.Drawing.Size(750, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(550, 400)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

    # ---- Title Label ----
    $script:titleLabel = New-Object System.Windows.Forms.Label
    $script:titleLabel.Text = 'MTB Trail Overlay Map Builder'
    $script:titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $script:titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $script:titleLabel.AutoSize = $false
    $script:titleLabel.Size = New-Object System.Drawing.Size(710, 32)
    $script:titleLabel.Location = New-Object System.Drawing.Point(10, 10)
    $script:titleLabel.Anchor = 'Top, Left, Right'
    $script:titleLabel.TextAlign = 'MiddleCenter'
    $form.Controls.Add($script:titleLabel)

    # ---- Country Row ----
    $script:countryLabel = New-Object System.Windows.Forms.Label
    $script:countryLabel.Text = 'Country:'
    $script:countryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:countryLabel.AutoSize = $true
    $script:countryLabel.Location = New-Object System.Drawing.Point(150, 55)
    $script:countryLabel.Anchor = 'Top'
    $form.Controls.Add($script:countryLabel)

    $script:countryCombo = New-Object System.Windows.Forms.ComboBox
    $countryCombo.DropDownStyle = 'DropDownList'
    $countryCombo.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $countryCombo.Size = New-Object System.Drawing.Size(250, 26)
    $countryCombo.Location = New-Object System.Drawing.Point(225, 52)
    $countryCombo.Anchor = 'Top'
    $RegionData.Keys | ForEach-Object { $countryCombo.Items.Add($_) | Out-Null }
    $countryCombo.SelectedIndex = 0
    $form.Controls.Add($countryCombo)

    # ---- Buttons ----
    $script:buildBtn = New-Object System.Windows.Forms.Button
    $buildBtn.Text = '  Build Map  '
    $buildBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $buildBtn.Size = New-Object System.Drawing.Size(130, 34)
    $buildBtn.Location = New-Object System.Drawing.Point(60, 95)
    $buildBtn.Anchor = 'Top'
    $buildBtn.UseVisualStyleBackColor = $true
    $buildBtn.Enabled = $false  # Enabled after prereq check
    $form.Controls.Add($buildBtn)

    $script:pushBtn = New-Object System.Windows.Forms.Button
    $pushBtn.Text = '  Push to Karoo  '
    $pushBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $pushBtn.Size = New-Object System.Drawing.Size(140, 34)
    $pushBtn.Location = New-Object System.Drawing.Point(200, 95)
    $pushBtn.Anchor = 'Top'
    $pushBtn.UseVisualStyleBackColor = $true
    $pushBtn.Enabled = $false  # Enabled after prereq check + map exists check
    $form.Controls.Add($pushBtn)

    $script:refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = ' Delete Cached Data '
    $refreshBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$refreshBtn.Size = New-Object System.Drawing.Size(150, 34)
$refreshBtn.Location = New-Object System.Drawing.Point(395, 95)
    $refreshBtn.Anchor = 'Top'
    $refreshBtn.UseVisualStyleBackColor = $true
    $refreshBtn.Enabled = $false  # Enabled after prereq check
    $form.Controls.Add($refreshBtn)

    # ---- Status Strip ----
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.SizingGrip = $true

    $script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Status: Checking prerequisites...'
    $statusLabel.Font = New-Object System.Drawing.Font('Consolas', 9)
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = 'MiddleLeft'

    $statusStrip.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusStrip)

    # ---- Log RichTextBox ----
    $script:logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.Location = New-Object System.Drawing.Point(10, 140)
    $logBox.Size = New-Object System.Drawing.Size(710, 365)
    $logBox.Anchor = 'Top, Bottom, Left, Right'
    $logBox.ReadOnly = $true
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $logBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $logBox.WordWrap = $false
    $logBox.HideSelection = $false
    $form.Controls.Add($logBox)

    # ---- Tooltip for warning messages ----
    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 10000
    $tooltip.InitialDelay = 500
    $tooltip.ReshowDelay = 100

    # ---- Center controls on resize ----
    $centerControls = {
        $formWidth = $form.ClientSize.Width
        # Center the country row
        $comboWidth = $countryCombo.Width
        $labelWidth = $script:countryLabel.Width
        $rowWidth = $labelWidth + 5 + $comboWidth
        $script:countryLabel.Left = [int](($formWidth - $rowWidth) / 2)
        $countryCombo.Left = $script:countryLabel.Right + 5

        # Center the button group
        $totalBtnWidth = $buildBtn.Width + 10 + $pushBtn.Width + 10 + $refreshBtn.Width
        $startX = [int](($formWidth - $totalBtnWidth) / 2)
        $buildBtn.Left = $startX
        $pushBtn.Left = $buildBtn.Right + 10
        $refreshBtn.Left = $pushBtn.Right + 10

        # Title label fills width
        $script:titleLabel.Width = $formWidth - 20
    }

    # Initial centering
    & $centerControls
    $form.add_Resize($centerControls)
}

# ============================================================
# MAIN ENTRY POINT
# ============================================================

# Build the UI
Build-UI

# Check prerequisites on load
Add-Log '============================================'
Add-Log '  MTB Trail Overlay Map Builder v1.0'
Add-Log '============================================'
Add-Log ''

# Ensure directories exist before any prerequisite checks
# (needed for bundled JRE/ADB install and map file detection)
if (-not (Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
}
$dataDir = Join-Path $ScriptDir 'data'
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

$javaPath = Test-Java
if (-not $javaPath) {
    # No Java 17+ found — try to install bundled JRE
    Add-Log ''
    Add-Log 'Java 17+ not found. Attempting to download bundled JRE 17...'
    $javaPath = Install-BundledJre
}
$script:JavaAvailable = $javaPath -ne $null
$script:JavaPath = $javaPath

$adbPath = Test-Adb
if (-not $adbPath) {
    # No ADB found — try to install bundled platform-tools
    Add-Log ''
    Add-Log 'ADB not found. Attempting to download Android Platform Tools...'
    $adbPath = Install-BundledAdb
}
$script:AdbAvailable = $adbPath -ne $null
$script:AdbPath = $adbPath

# Log prerequisite results
Add-Log ''
Add-Log 'Checking prerequisites...'
if ($JavaAvailable) {
    # Get Java version
    $javaVersion = & $javaPath -version 2>&1
    $versionLine = $javaVersion | Where-Object { $_ -match 'version' } | Select-Object -First 1
    Add-Log "  [OK] Java: $versionLine"
} else {
    Add-Log '  [WARNING] Java 17+ not found and auto-download failed.'
    Add-Log '  Build will be disabled. Install Java 17+ and restart.'
}

if ($AdbAvailable) {
    Add-Log "  [OK] ADB: $adbPath"
} else {
    Add-Log '  [WARNING] ADB not found and auto-download failed.'
    Add-Log '  Push to Karoo will be disabled. Install Android Platform Tools and restart.'
}

# Check build-tools directory (created early above, just log)
Add-Log "  [OK] Build directory: $BuildDir"

# Ensure theme file and icon assets are present
Ensure-ThemeFile
Ensure-IconAssets

Add-Log ''

# Enable/disable buttons
$buildBtn.Enabled = $JavaAvailable
$initialMap = Get-ChildItem (Join-Path $ScriptDir 'data') -Filter '*-mtb-overlay.map' -ErrorAction SilentlyContinue | Select-Object -First 1
$pushBtn.Enabled = $AdbAvailable -and ($initialMap -ne $null)
$refreshBtn.Enabled = $JavaAvailable

# Update status
if ($JavaAvailable) {
    $statusLabel.Text = 'Status: Ready'
} else {
    $statusLabel.Text = 'Status: Ready (Java missing - Build disabled)'
}

# ---- BUTTON EVENTS ----
# Uses synchronous execution with DoEvents() to keep UI responsive.
# BackgroundWorker doesn't work reliably in PowerShell because closures
# and script-scope variables don't marshal across threads.

$script:buildRunning = $false
$script:pushRunning = $false

$buildBtn.Add_Click({
    if ($script:buildRunning) { return }
    $script:buildRunning = $true
    $buildBtn.Enabled = $false
    $pushBtn.Enabled = $false
    $refreshBtn.Enabled = $false
    $logBox.Clear()
    $statusLabel.Text = 'Status: Building...'
    $form.Refresh()

    $displayName = $countryCombo.SelectedItem.ToString()
    try {
        Invoke-BuildPipeline -DisplayName $displayName
        $statusLabel.Text = 'Status: Done'
    } catch {
        Add-Log "BUILD ERROR: $($_.Exception.Message)"
        Add-Log "Stack: $($_.ScriptStackTrace)"
        $statusLabel.Text = 'Status: Error'
    }

    $script:buildRunning = $false
    $buildBtn.Enabled = $JavaAvailable
    $refreshBtn.Enabled = $JavaAvailable
    $currentCountry = $countryCombo.SelectedItem.ToString()
    $regionInfo = $RegionData[$currentCountry]
    $mapFile = Join-Path $ScriptDir "data\$($regionInfo.Key)-mtb-overlay.map"
    $pushBtn.Enabled = $AdbAvailable -and (Test-Path $mapFile)
})

$pushBtn.Add_Click({
    if ($script:pushRunning) { return }
    $script:pushRunning = $true
    $buildBtn.Enabled = $false
    $pushBtn.Enabled = $false
    $refreshBtn.Enabled = $false
    $logBox.Clear()
    $statusLabel.Text = 'Status: Pushing...'
    $form.Refresh()

    $displayName = $countryCombo.SelectedItem.ToString()
    try {
        Invoke-PushPipeline -DisplayName $displayName
        $statusLabel.Text = 'Status: Done'
    } catch {
        Add-Log "PUSH ERROR: $($_.Exception.Message)"
        Add-Log "Stack: $($_.ScriptStackTrace)"
        $statusLabel.Text = 'Status: Error'
    }

    $script:pushRunning = $false
    $buildBtn.Enabled = $JavaAvailable
    $refreshBtn.Enabled = $JavaAvailable
    $currentCountry = $countryCombo.SelectedItem.ToString()
    $regionInfo = $RegionData[$currentCountry]
    $mapFile = Join-Path $ScriptDir "data\$($regionInfo.Key)-mtb-overlay.map"
    $pushBtn.Enabled = $AdbAvailable -and (Test-Path $mapFile)
})

$refreshBtn.Add_Click({
    $displayName = $countryCombo.SelectedItem.ToString()
    $regionInfo = $RegionData[$displayName]
    $key = $regionInfo.Key
    $inputPbf = Join-Path $BuildDir "$key-latest.osm.pbf"
    $filteredPbf = Join-Path $BuildDir "$key-mtb-scale-only.osm.pbf"

    Add-Log ''
    Add-Log "=== Refreshing OSM data for $displayName ==="

    $deleted = @()
    if (Test-Path $inputPbf) {
        $size = (Get-Item $inputPbf).Length
        $sizeStr = Format-FileSize $size
        try {
            Remove-Item $inputPbf -Force -ErrorAction Stop
            $deleted += "PBF ($sizeStr)"
        } catch {
            Add-Log "  WARNING: Could not delete $($inputPbf) - file is locked."
            Add-Log "  Close any programs using it and try again."
        }
    }
    if (Test-Path $filteredPbf) {
        $size = (Get-Item $filteredPbf).Length
        $sizeStr = Format-FileSize $size
        try {
            Remove-Item $filteredPbf -Force -ErrorAction Stop
            $deleted += "Filtered PBF ($sizeStr)"
        } catch {
            Add-Log "  WARNING: Could not delete $($filteredPbf) - file is locked."
            Add-Log "  Close any programs using it and try again."
        }
    }

    if ($deleted.Count -gt 0) {
        Add-Log "  Deleted cached files: $($deleted -join ', ')"
        Add-Log "  Next build will download fresh data from Geofabrik."
        $statusLabel.Text = 'Status: Data refreshed'
    } else {
        Add-Log '  No cached data found for this region. Nothing to refresh.'
        $statusLabel.Text = 'Status: No data to refresh'
    }
})

# Update push button state when country changes
$countryCombo.Add_SelectedIndexChanged({
    $displayName = $countryCombo.SelectedItem.ToString()
    $regionInfo = $RegionData[$displayName]
    $mapFile = Join-Path $ScriptDir "data\$($regionInfo.Key)-mtb-overlay.map"
    $pushBtn.Enabled = $AdbAvailable -and (Test-Path $mapFile)
})

# ---- RUN ----
$form.Add_Shown({
    $logBox.AppendText("Welcome! Select a country and click 'Build Map' to start.`r`n")
    $logBox.AppendText("Or click 'Push to Karoo' to push an existing map to your device.`r`n")
    $logBox.AppendText("Click 'Delete Cached Data' to discard cached OSM data and re-download on next build.`r`n")
    $logBox.ScrollToCaret()
})
$form.ShowDialog() | Out-Null