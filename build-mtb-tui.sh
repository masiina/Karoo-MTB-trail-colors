#!/usr/bin/env bash
#
# build-mtb-tui.sh — Interactive TUI for building MTB trail overlay maps
#
# Usage:
#   ./build-mtb-tui.sh              # Interactive menu
#   ./build-mtb-tui.sh finland       # Non-interactive (delegates to build-mtb-overlay.sh)
#
# Prerequisites:
#   - whiptail (for TUI)
#   - Java JRE 17+ (JAVA_HOME or on PATH)
#   - osmium-tool
#   - curl
#
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# CONFIGURATION
# ============================================================

readonly APP_NAME="MTB Trail Overlay Map Builder"
readonly VERSION="1.0.0"
readonly BACKTITLE="${APP_NAME} v${VERSION}"

REGIONS=(
    "austria"
    "estonia"
    "finland"
    "france"
    "germany"
    "italy"
    "norway"
    "spain"
    "sweden"
    "switzerland"
)

declare -A REGION_NAMES
REGION_NAMES[austria]="Austria"
REGION_NAMES[estonia]="Estonia"
REGION_NAMES[finland]="Finland"
REGION_NAMES[france]="France"
REGION_NAMES[germany]="Germany"
REGION_NAMES[italy]="Italy"
REGION_NAMES[norway]="Norway"
REGION_NAMES[spain]="Spain"
REGION_NAMES[sweden]="Sweden"
REGION_NAMES[switzerland]="Switzerland"

declare -A GEOFABRIK_URLS
GEOFABRIK_URLS[finland]="https://download.geofabrik.de/europe/finland-latest.osm.pbf"
GEOFABRIK_URLS[germany]="https://download.geofabrik.de/europe/germany-latest.osm.pbf"
GEOFABRIK_URLS[norway]="https://download.geofabrik.de/europe/norway-latest.osm.pbf"
GEOFABRIK_URLS[sweden]="https://download.geofabrik.de/europe/sweden-latest.osm.pbf"
GEOFABRIK_URLS[estonia]="https://download.geofabrik.de/europe/estonia-latest.osm.pbf"
GEOFABRIK_URLS[spain]="https://download.geofabrik.de/europe/spain-latest.osm.pbf"
GEOFABRIK_URLS[france]="https://download.geofabrik.de/europe/france-latest.osm.pbf"
GEOFABRIK_URLS[italy]="https://download.geofabrik.de/europe/italy-latest.osm.pbf"
GEOFABRIK_URLS[austria]="https://download.geofabrik.de/europe/austria-latest.osm.pbf"
GEOFABRIK_URLS[switzerland]="https://download.geofabrik.de/europe/switzerland-latest.osm.pbf"

declare -A BBOXES
BBOXES[finland]="59.0,19.0,70.0,32.0"
BBOXES[germany]="46.0,5.0,55.5,15.5"
BBOXES[norway]="57.0,4.0,71.5,31.5"
BBOXES[sweden]="55.0,10.0,69.5,24.5"
BBOXES[estonia]="57.5,21.5,60.0,28.5"
BBOXES[spain]="36.0,-9.5,43.5,3.5"
BBOXES[france]="41.0,-5.5,51.5,10.0"
BBOXES[italy]="36.0,6.5,47.5,18.5"
BBOXES[austria]="46.0,9.5,49.5,17.5"
BBOXES[switzerland]="45.5,5.5,48.0,11.0"

declare -A START_POS
START_POS[finland]="61.5,25.0"
START_POS[germany]="51.0,10.5"
START_POS[norway]="65.0,14.0"
START_POS[sweden]="62.0,15.0"
START_POS[estonia]="59.0,25.0"
START_POS[spain]="40.0,-3.5"
START_POS[france]="46.5,2.0"
START_POS[italy]="42.5,12.5"
START_POS[austria]="47.5,13.5"
START_POS[switzerland]="46.8,8.0"

# ============================================================
# GLOBALS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-tools"
DATA_DIR="${SCRIPT_DIR}/data"
CHOSEN_REGION=""
FORCE_DOWNLOAD=false

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[34m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

OSMOSIS_DIR="${WORK_DIR}/osmosis"
MAPWRITER_JAR="${WORK_DIR}/mapsforge-map-writer.jar"
TAG_MAPPING="${WORK_DIR}/tag-mapping-mtb-merged.xml"

# Terminal state saved at startup for cleanup
SAVED_STTY=""
TMPDIR_SCRIPT=""

# ============================================================
# TRAP / CLEANUP
# ============================================================

cleanup() {
    local rc=$?
    # Restore terminal state (in case we were killed mid-whiptail)
    [[ -n "${SAVED_STTY:-}" ]] && stty "$SAVED_STTY" 2>/dev/null || true
    # Belt-and-suspenders: force sane tty mode
    stty sane 2>/dev/null || true
    # Remove temp directory if we created one
    [[ -n "${TMPDIR_SCRIPT:-}" && -d "$TMPDIR_SCRIPT" ]] && rm -rf "$TMPDIR_SCRIPT"
    # If we crashed, show the error on the restored terminal
    if [[ $rc -ne 0 && -n "${ERROR_MSG:-}" ]]; then
        echo "" >&2
        echo -e "${RED}[ERROR]${NC} ${ERROR_MSG}" >&2
        echo "" >&2
    fi
    exit "$rc"
}

on_error() {
    local rc=$?
    local line=${BASH_LINENO[0]:-unknown}
    # Save error info but don't exit — let cleanup EXIT trap handle display
    ERROR_MSG="Script failed at line $line (exit code $rc)"
}

SAVED_STTY=$(stty -g 2>/dev/null || true)
TMPDIR_SCRIPT=$(mktemp -d 2>/dev/null || echo "")
ERROR_MSG=""
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_error ERR

# ============================================================
# LOGGING
# ============================================================

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# Format a PBF file's size and modification date for display
pbf_info() {
    local pbf="$1"
    local size
    size=$(du -h "$pbf" | cut -f1 | tr -d ' ')
    local mtime
    mtime=$(date -d "@$(stat --format='%Y' "$pbf")" '+%Y-%m-%d' 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d' "$pbf" 2>/dev/null || echo "unknown")
    echo "${size}, ${mtime}"
}

# ============================================================
# WHIPTAIL WRAPPERS
# ============================================================
# These handle the fd-swap (3>&1 1>&2 2>&3) and make Cancel/ESC
# safe with set -e by using || true + empty-string checks.

require_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        log_err "whiptail is required for the TUI. Install: sudo apt install whiptail"
        exit 1
    fi
}

# Display-only widgets (no fd-swap needed, no capture)
wt_msgbox() {
    whiptail --backtitle "$BACKTITLE" --title "${1:-Info}" --msgbox "${2:-}" "${3:-10}" "${4:-60}"
}

wt_yesno() {
    # Returns 0 for Yes, 1 for No/Cancel — caller uses if/else
    whiptail --backtitle "$BACKTITLE" --title "${1:-Confirm}" --yesno "${2:-}" "${3:-10}" "${4:-60}"
}

# Capture widgets (need fd-swap, return empty string on cancel)
wt_menu() {
    local title="${1:-Menu}"
    local text="${2:-}"
    local height="${3:-20}"
    local width="${4:-65}"
    local listheight="${5:-10}"
    shift 5
    local result
    result=$(whiptail --backtitle "$BACKTITLE" --title "$title" \
        --menu "$text" "$height" "$width" "$listheight" "$@" 3>&1 1>&2 2>&3) || true
    echo "${result:-}"
}

wt_inputbox() {
    local title="${1:-Input}"
    local text="${2:-}"
    local default="${3:-}"
    local result
    result=$(whiptail --backtitle "$BACKTITLE" --title "$title" \
        --inputbox "$text" 8 60 "$default" 3>&1 1>&2 2>&3) || true
    echo "${result:-}"
}

# ============================================================
# PREREQUISITES
# ============================================================

check_prerequisites() {
    local missing_msgs=""

    if [[ -n "${JAVA_HOME:-}" ]]; then
        JAVA="${JAVA_HOME}/bin/java"
    else
        JAVA="java"
    fi

    if ! command -v "$JAVA" &>/dev/null && [[ ! -x "${JAVA:-}" ]]; then
        missing_msgs+="  • Java 17+ not found\n    Install: sudo apt install openjdk-17-jre\n    Or set JAVA_HOME if already installed\n"
    fi

    if ! command -v osmium &>/dev/null; then
        missing_msgs+="  • osmium not found (sudo apt install osmium-tool)\n"
    fi

    if ! command -v curl &>/dev/null; then
        missing_msgs+="  • curl not found (sudo apt install curl)\n"
    fi

    if [[ -n "$missing_msgs" ]]; then
        wt_msgbox "Prerequisites Missing" "Missing required tools:\n\n${missing_msgs}\nInstall them and try again." 12 65
        return 1
    fi

    log_ok "All prerequisites met"
    return 0
}

# ============================================================
# ENSURE THEME FILE
# ============================================================

ensure_theme_file() {
    local theme_file="${DATA_DIR}/offline_v15.xml"

    if [[ -f "$theme_file" ]]; then
        log_ok "Theme file: data/offline_v15.xml"
        return 0
    fi

    log_info "Theme file not found. Restoring from embedded copy..."
    mkdir -p "${DATA_DIR}"

    cat > "$theme_file" << 'THEME_EOF'
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

    <!-- Closed ways (except highways and buildings --> 
    <m closed="yes" e="way" k="highway|building" v="~">
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
            <m v="rock|bare_rock|stone|scree|glacier|cliff">
                <area mesh="true" fill="#cccccc"/>
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
    </m> <!--- End of closed ways -->

    <m k="natural" v="rock|bare_rock|stone|scree|glacier|cliff">
        <area mesh="true" fill="#cccccc"/>
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
THEME_EOF

    log_ok "Restored theme file: data/offline_v15.xml"
}

# ============================================================
# ENSURE OSMOSIS + MAPWRITER
# ============================================================

ensure_osmosis() {
    if [[ -x "${OSMOSIS_DIR}/bin/osmosis" ]] && [[ -f "${MAPWRITER_JAR}" ]]; then
        log_ok "Osmosis and map-writer already set up"
        return 0
    fi

    # --- Osmosis ---
    if [[ ! -x "${OSMOSIS_DIR}/bin/osmosis" ]]; then
        log_step "Setting up Osmosis"

        local OSMOSIS_VERSION="0.48.3"
        local OSMOSIS_URL="https://github.com/openstreetmap/osmosis/releases/download/${OSMOSIS_VERSION}/osmosis-${OSMOSIS_VERSION}.zip"
        if [[ ! -f "${WORK_DIR}/osmosis.zip" ]]; then
            log_info "Downloading Osmosis ${OSMOSIS_VERSION}..."
            curl -fsSL "$OSMOSIS_URL" -o "${WORK_DIR}/osmosis.zip" || { log_err "Failed to download Osmosis"; return 1; }
        fi

        if [[ ! -d "${OSMOSIS_DIR}" ]]; then
            log_info "Extracting Osmosis..."
            unzip -qo "${WORK_DIR}/osmosis.zip" -d "${OSMOSIS_DIR}"
        fi
    fi

    # --- Map-writer JAR (pre-built from Maven Central) ---
    # Downloads ~6 MB JAR instead of ~150 MB source + Gradle build
    if [[ ! -f "${MAPWRITER_JAR}" ]]; then
        local MAPSFORGE_VERSION="0.20.0"
        local MAPWRITER_URL="https://repo1.maven.org/maven2/org/mapsforge/mapsforge-map-writer/${MAPSFORGE_VERSION}/mapsforge-map-writer-${MAPSFORGE_VERSION}-jar-with-dependencies.jar"
        log_info "Downloading mapsforge-map-writer ${MAPSFORGE_VERSION}..."
        curl -fsSL "$MAPWRITER_URL" -o "${MAPWRITER_JAR}" || { log_err "Failed to download map-writer JAR"; return 1; }
        log_ok "Map-writer JAR downloaded ($(du -h "${MAPWRITER_JAR}" | cut -f1))"
    else
        log_ok "Map-writer JAR already downloaded"
    fi

    cp "${MAPWRITER_JAR}" "${OSMOSIS_DIR}/lib/default/"
    log_ok "Map-writer installed into Osmosis"
    return 0
}

# ============================================================
# GENERATE TAG-MAPPING
# ============================================================

generate_tag_mapping() {
    if [[ -f "${TAG_MAPPING}" ]]; then
        log_ok "Tag-mapping already generated"
        return 0
    fi

    log_info "Generating merged tag-mapping..."

    local DEFAULT_MAPPING_URL="https://raw.githubusercontent.com/mapsforge/mapsforge/master/mapsforge-map-writer/src/main/config/tag-mapping.xml"
    local DEFAULT_MAPPING="${WORK_DIR}/tag-mapping-default.xml"

    if [[ ! -f "${DEFAULT_MAPPING}" ]]; then
        log_info "Downloading default tag-mapping..."
        curl -fsSL "$DEFAULT_MAPPING_URL" -o "${DEFAULT_MAPPING}" || { log_err "Failed to download tag-mapping"; return 1; }
    fi

    cp "${DEFAULT_MAPPING}" "${TAG_MAPPING}"

    # Remove any existing MTB tags from the default mapping to avoid duplicates
    sed -i '/<osm-tag key="mtb:scale/d' "${TAG_MAPPING}"

    sed -i '/<\/ways>/i\
\        <!-- MTB SCALE -->\
        <osm-tag key="mtb:scale" value="0" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="1" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="2" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="3" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="4" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="5" zoom-appear="12"/>\
        <osm-tag key="mtb:scale" value="6" zoom-appear="12"/>\
        <osm-tag key="mtb:scale:uphill" value="0" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:uphill" value="1" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:uphill" value="2" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:uphill" value="3" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:uphill" value="4" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:uphill" value="5" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:imba" value="0" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:imba" value="1" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:imba" value="2" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:imba" value="3" zoom-appear="12" renderable="false"/>\
        <osm-tag key="mtb:scale:imba" value="4" zoom-appear="12" renderable="false"/>\
        <osm-tag key="natural" value="bare_rock" zoom-appear="12"/>\
' "${TAG_MAPPING}"

    log_ok "Tag-mapping generated"
    return 0
}

# ============================================================
# DOWNLOAD OSM DATA
# ============================================================

download_osm_data() {
    local region="$1"
    local url="${GEOFABRIK_URLS[$region]}"
    local pbf="${WORK_DIR}/${region}-latest.osm.pbf"

    if [[ -f "$pbf" ]] && [[ "$FORCE_DOWNLOAD" != "true" ]]; then
        local size
        size=$(du -h "$pbf" | cut -f1)
        log_ok "Using cached: ${pbf} ($size)"
        return 0
    fi

    log_step "Downloading OSM data for ${REGION_NAMES[$region]}"
    log_info "URL: $url"

    curl -L --progress-bar -o "$pbf" "$url"

    if [[ ! -f "$pbf" ]] || [[ ! -s "$pbf" ]]; then
        log_err "Download failed. Check your internet connection."
        return 1
    fi

    local size
    size=$(du -h "$pbf" | cut -f1)
    log_ok "Downloaded: $size"
    return 0
}

# ============================================================
# FILTER + BUILD
# ============================================================

build_map() {
    local region="$1"
    local input_pbf="${WORK_DIR}/${region}-latest.osm.pbf"
    local filtered_pbf="${WORK_DIR}/${region}-mtb-scale-only.osm.pbf"
    local output_map="${DATA_DIR}/${region}-mtb-overlay.map"
    local bbox="${BBOXES[$region]}"
    local start="${START_POS[$region]}"

    # --- Filter ---
    if [[ ! -f "${filtered_pbf}" ]] || [[ "${input_pbf}" -nt "${filtered_pbf}" ]]; then
        log_step "Filtering to mtb:scale ways and bare_rock areas"

        "${OSMOSIS_DIR}/bin/osmosis" \
            --rb file="${input_pbf}" \
            --tf accept-ways mtb:scale=* natural=bare_rock \
            --used-node \
            --wb file="${filtered_pbf}" omitmetadata=true 2>&1 | tail -5

        local fsize
        fsize=$(du -h "${filtered_pbf}" | cut -f1)
        log_ok "Filtered: $fsize"
    else
        local fsize
        fsize=$(du -h "${filtered_pbf}" | cut -f1)
        log_ok "Using cached filter: $fsize"
    fi

    # --- Build map ---
    log_step "Building Mapsforge map"

    local -a bbox_arr start_arr
    IFS=',' read -ra bbox_arr <<< "$bbox"
    local bottom="${bbox_arr[0]}" left="${bbox_arr[1]}" top="${bbox_arr[2]}" right="${bbox_arr[3]}"
    IFS=',' read -ra start_arr <<< "$start"
    local start_lat="${start_arr[0]}" start_lon="${start_arr[1]}"

    JAVACMD_OPTIONS="-Xmx2g" "${OSMOSIS_DIR}/bin/osmosis" \
        --rb file="${filtered_pbf}" \
        --mw file="${output_map}" \
             bbox="${bottom},${left},${top},${right}" \
             map-start-position="${start_lat},${start_lon}" \
             map-start-zoom=10 \
             tag-values=false \
             type=ram \
             preferred-languages=en,fi \
             threads="$(nproc)" \
             tag-conf-file="${TAG_MAPPING}" \
             progress-logs=true \
             zoom-interval-conf=5,0,7,10,8,11,14,12,21 2>&1 | tail -5

    if [[ ! -f "${output_map}" ]]; then
        log_err "Map build failed."
        return 1
    fi

    local map_size
    map_size=$(du -h "${output_map}" | cut -f1)
    log_ok "Build complete: ${output_map} ($map_size)"

    # Verify theme XML is in data/
    if [[ -f "${DATA_DIR}/offline_v15.xml" ]]; then
        log_ok "Theme: ${DATA_DIR}/offline_v15.xml"
    fi

    echo ""
    echo "=========================================="
    echo "  MAP BUILT SUCCESSFULLY"
    echo "=========================================="
    echo ""
    echo "  Output:  ${output_map}"
    echo "  Size:    $map_size"
    echo "  Region:  ${REGION_NAMES[$region]}"
    echo "  Bbox:    $bbox"
    echo ""
    echo "  To use on Hammerhead Karoo 3:"
    echo "  1. Copy files from data/ to your device"
    echo "  2. Add ${region}-mtb-overlay.map as overlay map alongside your base map"
    echo "  3. Use offline_v15.xml as shared theme"
    echo "  4. Enable both maps simultaneously"
    echo ""
    return 0
}

# ============================================================
# TUI: COUNTRY SELECTION
# ============================================================

show_country_menu() {
    local menu_items=()

    for region in "${REGIONS[@]}"; do
        local pbf="${WORK_DIR}/${region}-latest.osm.pbf"
        local status="not downloaded"
        if [[ -f "$pbf" ]]; then
            status="cached ($(pbf_info "$pbf"))"
        fi
        menu_items+=("$region" "${REGION_NAMES[$region]}  [$status]")
    done

    local choice
    choice=$(wt_menu "Select Country" \
        "\nSelect a country to build an overlay map for:" \
        20 65 10 "${menu_items[@]}")

    # Empty string = Cancel/ESC
    if [[ -z "$choice" ]]; then
        return 1
    fi

    CHOSEN_REGION="$choice"
    return 0
}

# ============================================================
# TUI: INTERACTIVE BUILD FLOW
# ============================================================

do_build_interactive() {
    local region=""

    # Step 1: Select country
    if ! show_country_menu; then
        log_info "Cancelled."
        return 0
    fi
    region="$CHOSEN_REGION"

    # Step 2: Check prerequisites
    if ! check_prerequisites; then
        return 1
    fi

    # Step 3: Confirm download if needed
    local pbf="${WORK_DIR}/${region}-latest.osm.pbf"
    if [[ -f "$pbf" ]]; then
        if wt_yesno "Cached Data Found" \
            "PBF data for ${REGION_NAMES[$region]} already cached ($(pbf_info "$pbf")).\n\nRe-download fresh data?"; then
            FORCE_DOWNLOAD=true
        else
            FORCE_DOWNLOAD=false
        fi
    else
        local url="${GEOFABRIK_URLS[$region]}"
        if ! wt_yesno "Download Required" \
            "No cached data for ${REGION_NAMES[$region]}.\n\nDownload from Geofabrik?\n\nURL: $url" 10 65; then
            log_info "Download cancelled."
            return 0
        fi
        FORCE_DOWNLOAD=true
    fi

    # Step 4: Confirm build
    if ! wt_yesno "Build Configuration" \
        "Ready to build MTB overlay map:\n\n\
  Country:     ${REGION_NAMES[$region]}\n\
  Bbox:        ${BBOXES[$region]}\n\
  Start pos:   ${START_POS[$region]}\n\
  Output:      data/${region}-mtb-overlay.map\n\
  Format:      Mapsforge V4\n\n\
Continue with build?" 15 55; then
        log_info "Build cancelled."
        return 0
    fi

    # Step 5: Build
    mkdir -p "${WORK_DIR}" "${DATA_DIR}"
    if ! ensure_osmosis; then return 1; fi
    if ! ensure_theme_file; then return 1; fi
    if ! generate_tag_mapping; then return 1; fi
    if ! download_osm_data "$region"; then return 1; fi
    if ! build_map "$region"; then return 1; fi

    wt_msgbox "Build Complete" \
        "MTB overlay map for ${REGION_NAMES[$region]} built successfully!\n\nCheck the terminal for details." 10 60

    return 0
}

# ============================================================
# TUI: REBUILD FROM CACHE
# ============================================================

do_rebuild_cache() {
    # Find cached PBF files
    local cached_regions=()
    for region in "${REGIONS[@]}"; do
        if [[ -f "${WORK_DIR}/${region}-latest.osm.pbf" ]]; then
            cached_regions+=("$region")
        fi
    done

    if [[ ${#cached_regions[@]} -eq 0 ]]; then
        wt_msgbox "No Cache" "No cached PBF data found.\nDownload data first (option 1)." 10 50
        return 0
    fi

    local region=""

    # If only one cached region, use it directly
    if [[ ${#cached_regions[@]} -eq 1 ]]; then
        region="${cached_regions[0]}"
    else
        # Multiple cached — let user pick
        local menu_items=()
        for r in "${cached_regions[@]}"; do
            menu_items+=("$r" "${REGION_NAMES[$r]}  ($(pbf_info "${WORK_DIR}/${r}-latest.osm.pbf"))")
        done

        local choice
        choice=$(wt_menu "Select Cached Region" \
            "Choose which cached region to re-build:" \
            15 60 6 "${menu_items[@]}")

        if [[ -z "$choice" ]]; then
            return 0
        fi
        region="$choice"
    fi

    # Confirm build
    local pbf_size
    pbf_size=$(pbf_info "${WORK_DIR}/${region}-latest.osm.pbf")
    if ! wt_yesno "Re-build Confirmation" \
        "Re-build overlay map for ${REGION_NAMES[$region]}?\n\nCached PBF: $pbf_size" 10 50; then
        return 0
    fi

    # Check prerequisites and build
    if ! check_prerequisites; then
        return 1
    fi
    mkdir -p "${WORK_DIR}" "${DATA_DIR}"
    if ! ensure_osmosis; then return 1; fi
    if ! ensure_theme_file; then return 1; fi
    if ! generate_tag_mapping; then return 1; fi

    FORCE_DOWNLOAD=false
    if ! build_map "$region"; then return 1; fi

    wt_msgbox "Build Complete" \
        "MTB overlay map for ${REGION_NAMES[$region]} rebuilt successfully!\n\nCheck the terminal for details." 10 60

    return 0
}

# ============================================================
# TUI: DELETE CACHED DATA
# ============================================================

do_delete_cache() {
    local count=0
    for region in "${REGIONS[@]}"; do
        [[ -f "${WORK_DIR}/${region}-latest.osm.pbf" ]] && ((count++)) || true
    done

    if [[ $count -eq 0 ]]; then
        wt_msgbox "No Cache" "No cached data to delete." 8 40
        return 0
    fi

    if wt_yesno "Delete Cache" \
        "Delete all cached PBF data ($count file(s))?\n\nThis will free disk space but you'll need to re-download to build again."; then
        rm -f "${WORK_DIR}"/*-latest.osm.pbf "${WORK_DIR}"/*-mtb-scale-only.osm.pbf
        wt_msgbox "Deleted" "Cached PBF files deleted.\n\nTools (Osmosis, map-writer) and tag-mapping are kept." 10 50
        log_ok "Cached PBF files deleted"
    fi
}

# ============================================================
# ADB HELPER — detect Linux adb or Windows adb.exe via WSL
# ============================================================

find_adb() {
    # In WSL2, Linux adb cannot see USB devices — prefer Windows adb.exe
    # Check for WSL first
    if grep -qi microsoft /proc/version 2>/dev/null; then
        local win_user
        win_user=$(ls /mnt/c/Users/ 2>/dev/null | grep -v -E '^(Public|Default|All|desktop\.ini|^$)' | head -1 || true)

        if [[ -n "$win_user" ]]; then
            local candidates=(
                "/mnt/c/Users/${win_user}/AppData/Local/Android/Sdk/platform-tools/adb.exe"
                "/mnt/c/Program Files/Android/platform-tools/adb.exe"
                "/mnt/c/Android/platform-tools/adb.exe"
            )
            for candidate in "${candidates[@]}"; do
                if [[ -x "$candidate" ]]; then
                    echo "$candidate"
                    return 0
                fi
            done
        fi
    fi

    # Native Linux adb (works on bare metal Linux, not WSL2)
    if command -v adb &>/dev/null; then
        echo "adb"
        return 0
    fi

    # Fallback: try Windows adb even if not in WSL (e.g., Cygwin)
    local win_user
    win_user=$(ls /mnt/c/Users/ 2>/dev/null | grep -v -E '^(Public|Default|All|desktop\.ini|^$)' | head -1 || true)
    if [[ -n "$win_user" ]]; then
        local candidates=(
            "/mnt/c/Users/${win_user}/AppData/Local/Android/Sdk/platform-tools/adb.exe"
            "/mnt/c/Program Files/Android/platform-tools/adb.exe"
            "/mnt/c/Android/platform-tools/adb.exe"
        )
        for candidate in "${candidates[@]}"; do
            if [[ -x "$candidate" ]]; then
                echo "$candidate"
                return 0
            fi
        done
    fi

    return 1
}

# Detect the Karoo's offline maps directory path
# Different firmware versions use /sdcard/ or /mnt/sdcard/
detect_karoo_maps_path() {
    local adb_cmd="$1"
    local paths=("/sdcard/offline/maps" "/mnt/sdcard/offline/maps" "/storage/emulated/0/offline/maps")

    for path in "${paths[@]}"; do
        if "$adb_cmd" shell "ls '$path/'" &>/dev/null; then
            echo "$path"
            return 0
        fi
    done

    # Fall back to creating the most common path
    echo "/sdcard/offline/maps"
    return 0
}

detect_karoo_theme_info() {
    local adb_cmd="$1"
    local paths=("/sdcard" "/mnt/sdcard" "/storage/emulated/0")

    for path in "${paths[@]}"; do
        # Look for any offline_v*.xml file in this path
        local found
        found=$("$adb_cmd" shell "ls '${path}/offline_v'*.xml 2>/dev/null" 2>/dev/null | head -1 | tr -d '\r')
        if [[ -n "$found" ]]; then
            local filename
            filename=$(basename "$found")
            echo "$path $filename"
            return 0
        fi
    done

    echo "/sdcard offline_v15.xml"
    return 0
}

# ============================================================
# TUI: PUSH TO KAROO DEVICE
# ============================================================

do_push_to_karoo() {
    # Find adb (Linux native or Windows via WSL)
    local adb_cmd
    adb_cmd=$(find_adb) || true

    if [[ -z "$adb_cmd" ]]; then
        wt_msgbox "ADB Not Found" \
            "adb is required to push files to the Karoo.\n\nLinux: sudo apt install adb\nWindows (via WSL): Install Android SDK Platform Tools\n  https://developer.android.com/tools/releases/platform-tools" 12 60
        return 1
    fi

    local adb_source="Linux adb"
    if [[ "$adb_cmd" == *".exe" ]]; then
        adb_source="Windows adb.exe (via WSL)"
    fi
    log_info "Using $adb_source: $adb_cmd"

    # Check for connected device
    log_info "Checking for connected device..."
    local device_count
    device_count=$("$adb_cmd" devices 2>/dev/null | grep -v "List of devices" | grep -c "device" || true)

    if [[ "$device_count" -eq 0 ]]; then
        wt_msgbox "No Device Found" \
            "No Android device detected via ADB.\n\nMake sure:\n  1. Karoo is connected via USB\n  2. USB Debugging is enabled\n     Settings → About → Build number (tap 7x)\n     Settings → Developer Options → USB Debugging\n  3. Accept the RSA authorization prompt on Karoo\n  4. Try: adb kill-server && adb start-server" 16 65
        return 1
    fi

    if [[ "$device_count" -gt 1 ]]; then
        wt_msgbox "Multiple Devices" \
            "$device_count Android devices detected.\n\nPlease connect only the Karoo and try again." 10 55
        return 1
    fi

    # Detect Karoo storage paths
    log_info "Detecting Karoo storage paths..."
    local maps_path theme_path_base theme_filename
    maps_path=$(detect_karoo_maps_path "$adb_cmd") || maps_path="/sdcard/offline/maps"
    read -r theme_path_base theme_filename <<< "$(detect_karoo_theme_info "$adb_cmd")"
    log_ok "Maps path: $maps_path"
    log_ok "Theme path: ${theme_path_base}/${theme_filename}"

    # Find map files to push
    local map_files=()
    for region in "${REGIONS[@]}"; do
        local map_file="${DATA_DIR}/${region}-mtb-overlay.map"
        if [[ -f "$map_file" ]]; then
            local map_size
            map_size=$(du -h "$map_file" | cut -f1 | tr -d ' ')
            map_files+=("$region" "${REGION_NAMES[$region]} ($map_size)")
        fi
    done

    if [[ ${#map_files[@]} -eq 0 ]]; then
        wt_msgbox "No Maps" "No overlay map files found.\n\nBuild a map first (option 1 or 2)." 10 50
        return 0
    fi

    # Select which map to push
    local region=""
    if [[ ${#map_files[@]} -eq 2 ]]; then
        region="${map_files[0]}"
    else
        local choice
        choice=$(wt_menu "Push to Karoo & Reboot" \
            "Select which overlay map to push:" \
            15 60 6 "${map_files[@]}")
        if [[ -z "$choice" ]]; then
            return 0
        fi
        region="$choice"
    fi

    local map_file="${DATA_DIR}/${region}-mtb-overlay.map"
    local map_size
    map_size=$(du -h "$map_file" | cut -f1)

    # Check if theme file exists
    local theme_file="${DATA_DIR}/offline_v15.xml"
    local theme_msg=""
    if [[ -f "$theme_file" ]]; then
        theme_msg="\n\nTheme file found: offline_v15.xml\nIt will be pushed as ${theme_filename} on the device."
    else
        theme_msg="\n\nNo offline_v15.xml found in data/ folder.\nYou will need to push the theme manually."
    fi

    if ! wt_yesno "Push to Karoo & Reboot" \
        "Push the following to the Karoo and reboot?\n\n  Map:   ${region}-mtb-overlay.map ($map_size)\n  Path:  ${maps_path}/${region}-mtb-overlay.map${theme_msg}\n\nImportant: Do NOT overwrite existing Hammerhead base maps.\nThe overlay uses a different filename, so it's safe.\n\nThe device will reboot after push to reload map data."; then
        return 0
    fi

    # Ensure target directory exists on device
    log_info "Ensuring target directory exists on Karoo..."
    "$adb_cmd" shell "mkdir -p '$maps_path'" 2>/dev/null || true

    # Push map file
    log_step "Pushing map file to Karoo"
    log_info "File: ${region}-mtb-overlay.map ($map_size)"
    if ! "$adb_cmd" push "$map_file" "${maps_path}/${region}-mtb-overlay.map"; then
        wt_msgbox "Push Failed" \
            "Failed to push map file to Karoo.\n\nCheck:\n  • USB connection is stable\n  • Karoo storage has free space\n  • adb devices shows the unit" 12 60
        return 1
    fi
    log_ok "Map file pushed successfully"

    # Push theme if available
    if [[ -f "$theme_file" ]]; then
        log_step "Pushing theme file to Karoo"
        # Backup existing theme on device first
        "$adb_cmd" shell "cp '${theme_path_base}/${theme_filename}' '${theme_path_base}/${theme_filename}.bak'" 2>/dev/null && log_ok "Backed up existing theme: ${theme_filename}.bak" || log_info "Could not back up existing theme (may not exist yet)"
        if ! "$adb_cmd" push "$theme_file" "${theme_path_base}/${theme_filename}"; then
            wt_msgbox "Theme Push Failed" \
                "Map was pushed but theme push failed.\n\nTry pushing manually:\n  adb push data/offline_v15.xml ${theme_path_base}/${theme_filename}" 12 60
            return 1
        fi
        log_ok "Theme file pushed successfully"
    fi

    log_step "Rebooting Karoo to reload map data"
    "$adb_cmd" reboot
    log_ok "Device is rebooting"

    wt_msgbox "Push Complete" \
        "Files pushed to Karoo successfully!\n\nRebooting device to reload map data...\nThe overlay map will be available after restart." 10 60

    return 0
}

# ============================================================
# TUI: MAIN MENU LOOP
# ============================================================

main_menu() {
    while :; do
        # Scan for cached PBF files
        local pbf_count=0
        local pbf_list=""
        for region in "${REGIONS[@]}"; do
            if [[ -f "${WORK_DIR}/${region}-latest.osm.pbf" ]]; then
                pbf_list+="  ${REGION_NAMES[$region]}: $(pbf_info "${WORK_DIR}/${region}-latest.osm.pbf")\n"
                ((pbf_count++)) || true
            fi
        done

        local msg="MTB Trail Overlay Map Builder\n\n"
        if [[ $pbf_count -gt 0 ]]; then
            msg+="Cached PBF data ($pbf_count region(s)):\n${pbf_list}\n"
        else
            msg+="No cached PBF data. Select a country to download.\n\n"
        fi
        msg+="Choose an action:"

        local choice
        choice=$(wt_menu "$APP_NAME" "$msg" 20 65 5 \
            "1" "Select country & build overlay map" \
            "2" "Re-build from cached data" \
            "3" "Push map to Karoo & reboot device" \
            "4" "Delete cached PBF data" \
            "5" "Exit")

        # Cancel/ESC → exit
        if [[ -z "$choice" ]]; then
            log_info "Goodbye!"
            return 0
        fi

        case "$choice" in
            1)
                do_build_interactive
                echo ""
                echo "Press Enter to return to menu..."
                read -r
                ;;
            2)
                do_rebuild_cache
                echo ""
                echo "Press Enter to return to menu..."
                read -r
                ;;
            3)
                do_push_to_karoo
                echo ""
                echo "Press Enter to return to menu..."
                read -r
                ;;
            4)
                do_delete_cache
                ;;
            5)
                log_info "Goodbye!"
                return 0
                ;;
        esac
    done
}

# ============================================================
# ENTRY POINT
# ============================================================

mkdir -p "${WORK_DIR}" "${DATA_DIR}"
# If called with command-line arguments, delegate to the non-interactive script
if [[ $# -gt 0 ]]; then
    exec "${SCRIPT_DIR}/build-mtb-overlay.sh" "$@"
fi

# Otherwise, run interactive TUI
require_whiptail
main_menu