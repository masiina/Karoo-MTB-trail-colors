#!/usr/bin/env bash
#
# build-mtb-overlay.sh — Build a Mapsforge MTB trail overlay map
#
# Usage:
#   ./build-mtb-overlay.sh                          # Build for Finland (default)
#   ./build-mtb-overlay.sh germany                  # Build for Germany
#   ./build-mtb-overlay.sh 60.0,24.0,60.5,25.0 helsinki  # Custom bbox + name
#   ./build-mtb-overlay.sh --download finland        # Download fresh data first
#
# Prerequisites:
#   - Java JRE 17+ (JAVA_HOME must be set, or java must be on PATH)
#   - osmium-tool (osmium command)
#   - curl, wget, or similar for downloading
#
# The script will:
#   1. Download OSM data from Geofabrik (if not cached)
#   2. Filter to only ways with mtb:scale=* tags
#   3. Build a Mapsforge .map file using the merged default+MTB tag-mapping
#   4. Optionally push the map to a connected Karoo device via ADB
#
# Usage:
#   ./build-mtb-overlay.sh                          # Build for Finland (default)
#   ./build-mtb-overlay.sh germany                  # Build for Germany
#   ./build-mtb-overlay.sh --download finland        # Download fresh data first
#   ./build-mtb-overlay.sh --push finland            # Build and push to Karoo
#   ./build-mtb-overlay.sh --push-only finland       # Push existing map only
#
# Output: data/<name>-mtb-overlay.map
#
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

# Geofabrik download URLs (add more regions as needed)
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

# Default bounding boxes (S,W,N,E in degrees)
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

# Default map start positions (lat,lon)
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
# ARGUMENT PARSING
# ============================================================

DOWNLOAD=false
PUSH=false
PUSH_ONLY=false
REGION="finland"
CUSTOM_BBOX=""
CUSTOM_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --download|-d)
            DOWNLOAD=true
            shift
            ;;
        --push|-p)
            PUSH=true
            shift
            ;;
        --push-only)
            PUSH_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--download] [--push] [--push-only] [region | bbox name]"
            echo ""
            echo "Regions: ${!GEOFABRIK_URLS[*]}"
            echo ""
            echo "Custom bbox: $0 S,W,N,E name"
            echo "  Example: $0 60.0,24.0,60.5,25.0 helsinki"
            echo ""
            echo "Options:"
            echo "  --download, -d   Force re-download OSM data even if cached"
            echo "  --push, -p       Push map to Karoo device via ADB after build"
            echo "  --push-only      Push existing map to Karoo (skip build)"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
        *)
            # Check if it looks like a bbox (contains commas)
            if [[ "$1" == *,* ]]; then
                CUSTOM_BBOX="$1"
                shift
                CUSTOM_NAME="$1"
                if [[ -z "$CUSTOM_NAME" ]]; then
                    echo "ERROR: Must provide a name when using custom bbox"
                    exit 1
                fi
            else
                REGION="$1"
            fi
            shift
            ;;
    esac
done

# Set region name and parameters
if [[ -n "$CUSTOM_BBOX" ]]; then
    MAP_NAME="$CUSTOM_NAME"
    BBOX="$CUSTOM_BBOX"
    # Parse start position from bbox center
    BBOX_ARR=(${BBOX//,/ })
    START_LAT=$(echo "scale=2; (${BBOX_ARR[0]} + ${BBOX_ARR[2]}) / 2" | bc)
    START_LON=$(echo "scale=2; (${BBOX_ARR[1]} + ${BBOX_ARR[3]}) / 2" | bc)
    START="${START_LAT},${START_LON}"
    PBF_URL=""
else
    MAP_NAME="$REGION"
    BBOX="${BBOXES[$REGION]:-59.0,19.0,70.0,32.0}"
    START="${START_POS[$REGION]:-61.5,25.0}"
    PBF_URL="${GEOFABRIK_URLS[$REGION]:-}"
    if [[ -z "$PBF_URL" ]]; then
        echo "ERROR: Unknown region '$REGION'. Available: ${!GEOFABRIK_URLS[*]}"
        echo "       Or use a custom bbox: $0 S,W,N,E name"
        exit 1
    fi
fi

# ============================================================
# SETUP DIRECTORIES
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/build-tools"
DATA_DIR="${SCRIPT_DIR}/data"
mkdir -p "${WORK_DIR}" "${DATA_DIR}"

OUTPUT_FILE="${DATA_DIR}/${MAP_NAME}-mtb-overlay.map"

# ============================================================
# CHECK PREREQUISITES
# ============================================================

echo "=== MTB Trail Overlay Map Builder ==="
echo ""
echo "Region:    ${MAP_NAME}"
echo "Bbox:      ${BBOX}"
echo "Start:     ${START}"
echo "Output:    ${OUTPUT_FILE}"
echo ""

# Java
if [[ -n "${JAVA_HOME:-}" ]]; then
    JAVA="${JAVA_HOME}/bin/java"
else
    JAVA="java"
fi

if ! command -v "$JAVA" &>/dev/null && [[ ! -x "$JAVA" ]]; then
    echo "ERROR: Java not found. Install JDK 17+ and set JAVA_HOME."
    exit 1
fi

# Osmium
if ! command -v osmium &>/dev/null; then
    echo "ERROR: osmium not found. Install osmium-tool (apt install osmium-tool)."
    exit 1
fi

# ============================================================
# BUILD OSMOSIS + MAPWRITER IF NEEDED
# ============================================================

OSMOSIS_DIR="${WORK_DIR}/osmosis"
MAPWRITER_JAR="${WORK_DIR}/mapsforge-map-writer.jar"

# ============================================================
# ENSURE THEME FILE
# ============================================================

ensure_theme_file() {
    local theme_file="${DATA_DIR}/offline_v15.xml"

    if [[ -f "$theme_file" ]]; then
        echo "Theme file: data/offline_v15.xml"
        return 0
    fi

    echo "Theme file not found at ${theme_file}. Restoring from embedded copy..."
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

    echo "Restored theme file: data/offline_v15.xml"
}

build_osmosis() {
    if [[ -x "${OSMOSIS_DIR}/bin/osmosis" ]]; then
        echo "Osmosis already built at ${OSMOSIS_DIR}"
    else
        echo "--- Setting up Osmosis ---"

        local OSMOSIS_VERSION="0.48.3"
        local OSMOSIS_URL="https://github.com/openstreetmap/osmosis/releases/download/${OSMOSIS_VERSION}/osmosis-${OSMOSIS_VERSION}.zip"
        if [[ ! -f "${WORK_DIR}/osmosis.zip" ]]; then
            echo "Downloading Osmosis ${OSMOSIS_VERSION}..."
            curl -fsSL "$OSMOSIS_URL" -o "${WORK_DIR}/osmosis.zip"
        fi

        echo "Extracting Osmosis..."
        unzip -qo "${WORK_DIR}/osmosis.zip" -d "${OSMOSIS_DIR}"
    fi

    # Download pre-built map-writer JAR from Maven Central
    # (eliminates ~150 MB source download + multi-minute Gradle build)
    if [[ ! -f "${MAPWRITER_JAR}" ]]; then
        local MAPSFORGE_VERSION="0.20.0"
        local MAPWRITER_URL="https://repo1.maven.org/maven2/org/mapsforge/mapsforge-map-writer/${MAPSFORGE_VERSION}/mapsforge-map-writer-${MAPSFORGE_VERSION}-jar-with-dependencies.jar"
        echo "Downloading mapsforge-map-writer ${MAPSFORGE_VERSION}..."
        curl -fsSL "$MAPWRITER_URL" -o "${MAPWRITER_JAR}"
        echo "Map-writer jar: ${MAPWRITER_JAR} ($(du -h "${MAPWRITER_JAR}" | cut -f1))"
    else
        echo "Map-writer jar already downloaded: ${MAPWRITER_JAR}"
    fi

    # Install jar into Osmosis
    cp "${MAPWRITER_JAR}" "${OSMOSIS_DIR}/lib/default/"
    echo "Map-writer installed into Osmosis"
}

build_osmosis
ensure_theme_file

# ============================================================
# GENERATE MERGED TAG-MAPPING
# ============================================================

TAG_MAPPING="${WORK_DIR}/tag-mapping-mtb-merged.xml"

generate_tag_mapping() {
    if [[ -f "${TAG_MAPPING}" ]]; then
        echo "Tag-mapping already generated at ${TAG_MAPPING}"
        return
    fi

    echo "--- Generating merged tag-mapping ---"

    local MAPSFORGE_VERSION="0.20.0"
    local DEFAULT_MAPPING_URL="https://raw.githubusercontent.com/mapsforge/mapsforge/master/mapsforge-map-writer/src/main/config/tag-mapping.xml"
    local DEFAULT_MAPPING="${WORK_DIR}/tag-mapping-default.xml"

    # Download default tag-mapping
    if [[ ! -f "${DEFAULT_MAPPING}" ]]; then
        echo "Downloading default tag-mapping..."
        curl -fsSL "$DEFAULT_MAPPING_URL" -o "${DEFAULT_MAPPING}"
    fi

    # Append MTB-specific tags
    cp "${DEFAULT_MAPPING}" "${TAG_MAPPING}"

    # Remove any existing MTB tags from the default mapping to avoid duplicates
    sed -i '/<osm-tag key="mtb:scale/d' "${TAG_MAPPING}"

    # Add MTB tags before the closing </ways> tag
    sed -i '/<\/ways>/i\
\        <!-- MTB SCALE (added by build-mtb-overlay.sh) -->\
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
' "${TAG_MAPPING}"

    echo "Tag-mapping generated: ${TAG_MAPPING}"
}

generate_tag_mapping

# ============================================================
# DOWNLOAD OSM DATA
# ============================================================

INPUT_PBF="${WORK_DIR}/${MAP_NAME}-latest.osm.pbf"
FILTERED_PBF="${WORK_DIR}/${MAP_NAME}-mtb-scale-only.osm.pbf"

if [[ -n "$PBF_URL" ]]; then
    if [[ ! -f "${INPUT_PBF}" ]] || [[ "$DOWNLOAD" == "true" ]]; then
        echo "--- Downloading OSM data for ${MAP_NAME} ---"
        curl -L -o "${INPUT_PBF}" "$PBF_URL"
        echo "Downloaded: ${INPUT_PBF} ($(du -h "${INPUT_PBF}" | cut -f1))"
    else
        echo "Using cached: ${INPUT_PBF} ($(du -h "${INPUT_PBF}" | cut -f1))"
    fi
else
    # Custom bbox — user must provide the PBF file
    if [[ ! -f "${INPUT_PBF}" ]]; then
        echo "ERROR: No Geofabrik URL for custom region."
        echo "       Place your OSM PBF file at: ${INPUT_PBF}"
        echo "       Or download from: https://download.geofabrik.de/"
        exit 1
    fi
fi

# ============================================================
# FILTER TO MTB:SCALE WAYS ONLY
# ============================================================

if [[ "$PUSH_ONLY" != "true" ]]; then

if [[ ! -f "${FILTERED_PBF}" ]] || [[ "${INPUT_PBF}" -nt "${FILTERED_PBF}" ]]; then
    echo ""
    echo "--- Filtering to mtb:scale ways ---"

    "${OSMOSIS_DIR}/bin/osmosis" \
        --rb file="${INPUT_PBF}" \
        --tf accept-ways mtb:scale=* \
        --used-node \
        --wb file="${FILTERED_PBF}" omitmetadata=true

    echo "Filtered: ${FILTERED_PBF} ($(du -h "${FILTERED_PBF}" | cut -f1))"
else
    echo "Using cached filter: ${FILTERED_PBF} ($(du -h "${FILTERED_PBF}" | cut -f1))"
fi

# ============================================================
# BUILD MAPSFORGE MAP
# ============================================================

echo ""
echo "--- Building Mapsforge map ---"
echo "  Output:    ${OUTPUT_FILE}"
echo "  Bbox:      ${BBOX}"
echo "  Start:     ${START}"
echo ""

# Parse bbox for osmosis
BBOX_ARR=(${BBOX//,/ })
BOTTOM="${BBOX_ARR[0]}"
LEFT="${BBOX_ARR[1]}"
TOP="${BBOX_ARR[2]}"
RIGHT="${BBOX_ARR[3]}"

# Parse start position
START_ARR=(${START//,/ })
START_LAT="${START_ARR[0]}"
START_LON="${START_ARR[1]}"

JAVACMD_OPTIONS="-Xmx1g" "${OSMOSIS_DIR}/bin/osmosis" \
    --rb file="${FILTERED_PBF}" \
    --mw file="${OUTPUT_FILE}" \
         bbox="${BOTTOM},${LEFT},${TOP},${RIGHT}" \
         map-start-position="${START_LAT},${START_LON}" \
         map-start-zoom=10 \
         tag-values=false \
         type=ram \
         preferred-languages=en,fi \
         threads="$(nproc)" \
         tag-conf-file="${TAG_MAPPING}" \
         progress-logs=true \
         zoom-interval-conf=5,0,7,10,8,11,14,12,21

echo ""
echo "=== Build complete ==="
echo ""
echo "Output: ${OUTPUT_FILE} ($(du -h "${OUTPUT_FILE}" | cut -f1))"

# Verify theme XML is in data/
if [[ -f "${DATA_DIR}/offline_v15.xml" ]]; then
    echo "Theme:  ${DATA_DIR}/offline_v15.xml"
fi

echo ""
echo "Usage on Hammerhead Karoo 3:"
echo "  1. Copy files from data/ to your device"
echo "  2. Add ${MAP_NAME}-mtb-overlay.map as overlay map alongside your base map"
echo "  3. Use offline_v15.xml as the shared theme for both maps"
echo "  4. Enable both maps simultaneously"
echo ""
echo "Or use --push to push directly via ADB:"
echo "  $0 --push ${REGION}"

fi # end PUSH_ONLY skip block

# ============================================================
# PUSH TO KAROO
# ============================================================

# Detect adb — Linux native or Windows adb.exe via WSL
find_adb() {
    # In WSL2, Linux adb cannot see USB devices — prefer Windows adb.exe
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

    # Fallback: try Windows adb even if not in WSL
    local win_user
    win_user=$(ls /mnt/c/Users/ 2>/dev/null | grep -v -E '^(Public|Default|All|^$)' | head -1 || true)
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
detect_karoo_maps_path() {
    local adb_cmd="$1"
    local paths=("/sdcard/offline/maps" "/mnt/sdcard/offline/maps" "/storage/emulated/0/offline/maps")

    for path in "${paths[@]}"; do
        if "$adb_cmd" shell "ls '$path/'" &>/dev/null; then
            echo "$path"
            return 0
        fi
    done

    echo "/sdcard/offline/maps"
    return 0
}

detect_karoo_theme_path() {
    local adb_cmd="$1"
    local paths=("/sdcard" "/mnt/sdcard" "/storage/emulated/0")

    for path in "${paths[@]}"; do
        if "$adb_cmd" shell "ls '${path}/offline_v15.xml'" &>/dev/null; then
            echo "$path"
            return 0
        fi
    done

    echo "/sdcard"
    return 0
}

push_to_karoo() {
    echo ""
    echo "=== Pushing to Karoo device ==="
    echo ""

    local adb_cmd
    adb_cmd=$(find_adb) || true

    if [[ -z "$adb_cmd" ]]; then
        echo "ERROR: adb not found."
        echo ""
        echo "Linux: sudo apt install adb"
        echo "Windows (via WSL): Install Android SDK Platform Tools"
        echo "  https://developer.android.com/tools/releases/platform-tools"
        return 1
    fi

    local adb_source="Linux adb"
    if [[ "$adb_cmd" == *".exe" ]]; then
        adb_source="Windows adb.exe (via WSL)"
    fi
    echo "Using $adb_source: $adb_cmd"

    # Check for connected device
    local device_count
    device_count=$("$adb_cmd" devices 2>/dev/null | grep -v "List of devices" | grep -c "device" || true)

    if [[ "$device_count" -eq 0 ]]; then
        echo "ERROR: No Android device detected via ADB."
        echo ""
        echo "Make sure:"
        echo "  1. Karoo is connected via USB"
        echo "  2. USB Debugging is enabled (Settings → Developer Options)"
        echo "  3. RSA authorization prompt is accepted on the Karoo"
        echo "  4. Try: $adb_cmd kill-server && $adb_cmd start-server"
        return 1
    fi

    if [[ "$device_count" -gt 1 ]]; then
        echo "ERROR: Multiple Android devices detected. Connect only the Karoo."
        return 1
    fi

    # Detect Karoo storage paths
    echo "Detecting Karoo storage paths..."
    local maps_path theme_path_base
    maps_path=$(detect_karoo_maps_path "$adb_cmd")
    theme_path_base=$(detect_karoo_theme_path "$adb_cmd")
    echo "  Maps path:  $maps_path"
    echo "  Theme path: ${theme_path_base}/offline_v15.xml"

    # Ensure target directory exists
    "$adb_cmd" shell "mkdir -p '$maps_path'" 2>/dev/null || true

    # Push map file
    echo "Pushing ${OUTPUT_FILE}..."
    if ! "$adb_cmd" push "${OUTPUT_FILE}" "${maps_path}/$(basename "${OUTPUT_FILE}")"; then
        echo "ERROR: Failed to push map file."
        return 1
    fi
    echo "Map file pushed successfully."

    # Push theme if available
    local theme_file="${DATA_DIR}/offline_v15.xml"
    if [[ -f "$theme_file" ]]; then
        echo "Pushing theme file..."
        "$adb_cmd" shell "cp '${theme_path_base}/offline_v15.xml' '${theme_path_base}/offline_v15.xml.bak'" 2>/dev/null || true
        if "$adb_cmd" push "$theme_file" "${theme_path_base}/offline_v15.xml"; then
            echo "Theme file pushed successfully."
        else
            echo "WARNING: Failed to push theme file. Push manually:"
            echo "  $adb_cmd push offline_v15.xml ${theme_path_base}/offline_v15.xml"
        fi
    else
        echo "NOTE: No offline_v15.xml found in data/. Place the theme file there to push it."
    fi

    echo ""
    echo "=== Push complete ==="
    echo ""
    echo "On the Karoo:"
    echo "  1. Reopen the map screen"
    echo "  2. The overlay map should appear as a layer"
    echo "  3. Enable both base map and overlay map"
    echo ""
}

if [[ "$PUSH_ONLY" == "true" ]]; then
    # Skip build, just push existing map
    if [[ ! -f "${OUTPUT_FILE}" ]]; then
        echo "ERROR: ${OUTPUT_FILE} not found. Build first or check the path."
        exit 1
    fi
    push_to_karoo
elif [[ "$PUSH" == "true" ]]; then
    # Build already completed above, now push
    push_to_karoo
fi