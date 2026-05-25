#!/bin/bash

# Script to configure ue_template.conf with values from JSON files
# Terrestrial UE — supports Physical (USRP) and RFSimulator modes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LAST_CONFIG_FILE=".ue_last_config"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

# Detect docker compose command once
if docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
elif docker-compose version &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo -e "${RED}Error: neither 'docker compose' nor 'docker-compose' found.${NC}"
    exit 1
fi

# ─── Display ──────────────────────────────────────────────────────────────────

display_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}    UE Configuration Tool - Terrestrial${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

# ─── Mode selection ───────────────────────────────────────────────────────────

select_mode() {
    echo -e "${BLUE}Select operation mode:${NC}" >&2
    echo "" >&2
    echo -e "  ${GREEN}1)${NC} Physical    — USRP hardware (B210 / X310)" >&2
    echo -e "  ${GREEN}2)${NC} RFSimulator — software only, no hardware required" >&2
    echo "" >&2
    local _mc
    while true; do
        read -p "Enter number (1-2) [default: 1]: " _mc >&2
        _mc="${_mc:-1}"
        case "$_mc" in
            1) echo "physical"; return 0 ;;
            2) echo "rfsim";    return 0 ;;
            *) echo -e "${RED}Invalid selection. Enter 1 or 2.${NC}" >&2 ;;
        esac
    done
}

mode_label() {
    if [ "$1" == "rfsim" ]; then echo "RFSimulator"; else echo "Physical (USRP)"; fi
}

# ─── Last config persistence ──────────────────────────────────────────────────

save_last_config() {
    local mode="$1" ru_file="$2" cells_file="$3" additional_file="$4" gnb_ip="$5"
    cat > "$LAST_CONFIG_FILE" << EOF
MODE=$mode
RU_FILE=$ru_file
CELLS_FILE=$cells_file
ADDITIONAL_FILE=$additional_file
GNB_IP=$gnb_ip
EOF
    echo -e "${GREEN}Configuration saved for next time.${NC}"
}

load_last_config() {
    [ -f "$LAST_CONFIG_FILE" ] || return 1
    source "$LAST_CONFIG_FILE"
    MODE="${MODE:-physical}"
    GNB_IP="${GNB_IP:-172.22.0.25}"
    if [ -f "$RU_FILE" ] && [ -f "$CELLS_FILE" ]; then return 0; fi
    echo -e "${YELLOW}Last configuration files no longer exist.${NC}"
    return 1
}

show_last_config_menu() {
    echo -e "${BLUE}Last used configuration:${NC}"
    echo -e "  ${CYAN}Mode:${NC}  $(mode_label "$MODE")"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$RU_FILE")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$CELLS_FILE")"
    if [ "$MODE" == "rfsim" ]; then
        echo -e "  ${CYAN}gNB IP:${NC} ${GNB_IP}"
    elif [ -n "$ADDITIONAL_FILE" ] && [ "$ADDITIONAL_FILE" != "none" ]; then
        echo -e "  ${CYAN}Extra:${NC} $(basename "$ADDITIONAL_FILE")"
    else
        echo -e "  ${CYAN}Extra:${NC} (none)"
    fi
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  ${GREEN}1)${NC} Use last configuration"
    echo -e "  ${GREEN}2)${NC} Select new configuration"
    echo ""
    read -p "Choose option [1]: " choice
    [ "${choice:-1}" == "1" ] && return 0 || return 1
}

# ─── File selection ───────────────────────────────────────────────────────────

select_file() {
    local dir="$1" description="$2" pattern="${3:-*.json}"
    local files=()

    if [ ! -d "$dir" ]; then
        echo -e "${RED}Error: Directory not found: $dir${NC}" >&2; return 1
    fi

    while IFS= read -r f; do files+=("$f"); done \
        < <(find "$dir" -maxdepth 2 -name "$pattern" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Error: No JSON files found in $dir${NC}" >&2; return 1
    fi

    echo -e "${BLUE}Select $description:${NC}" >&2
    echo "" >&2
    for i in "${!files[@]}"; do
        printf "  ${GREEN}%2d)${NC} %s\n" $((i+1)) "$(basename "${files[$i]}")" >&2
    done
    echo "" >&2

    local selection=""
    while true; do
        read -p "Enter number (1-${#files[@]}): " selection >&2
        if [[ "$selection" =~ ^[0-9]+$ ]] && \
           [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
            echo "${files[$((selection-1))]}"; return 0
        fi
        echo -e "${RED}Invalid selection.${NC}" >&2
    done
}

select_additional_options_file() {
    local dir="$1"
    local files=()

    echo -e "${BLUE}Additional Options file (optional):${NC}" >&2
    echo -e "${YELLOW}  Extra CLI flags exported as USE_ADDITIONAL_OPTIONS.${NC}" >&2
    echo -e "  ${GREEN}0)${NC} Skip (no additional options)" >&2

    if [ ! -d "$dir" ]; then
        echo -e "${YELLOW}  (Directory not found — skip only)${NC}" >&2; echo "" >&2
        read -p "Press Enter to skip, or enter full path to a JSON file: " mp >&2
        if [ -z "$mp" ]; then echo "none"; return 0
        elif [ -f "$mp" ]; then echo "$mp"; return 0
        else echo -e "${RED}Not found — skipping.${NC}" >&2; echo "none"; return 0; fi
    fi

    while IFS= read -r f; do files+=("$f"); done \
        < <(find "$dir" -maxdepth 2 -name "*.json" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No files found — skip only.${NC}" >&2; echo "" >&2
        read -p "Press Enter to skip, or enter full path to a JSON file: " mp >&2
        if [ -z "$mp" ]; then echo "none"; return 0
        elif [ -f "$mp" ]; then echo "$mp"; return 0
        else echo -e "${RED}Not found — skipping.${NC}" >&2; echo "none"; return 0; fi
    fi

    for i in "${!files[@]}"; do
        printf "  ${GREEN}%2d)${NC} %s\n" $((i+1)) "$(basename "${files[$i]}")" >&2
    done
    echo "" >&2

    while true; do
        read -p "Enter number (0 to skip, 1-${#files[@]}): " selection >&2
        if [ "$selection" == "0" ] || [ -z "$selection" ]; then
            echo "none"; return 0
        elif [[ "$selection" =~ ^[0-9]+$ ]] && \
             [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
            echo "${files[$((selection-1))]}"; return 0
        fi
        echo -e "${RED}Invalid selection.${NC}" >&2
    done
}

confirm_selection() {
    echo ""
    echo -e "${YELLOW}Selected configurations:${NC}"
    echo -e "  ${CYAN}Mode:${NC}  $(mode_label "$MODE")"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$1")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$2")"
    if [ "$MODE" == "rfsim" ]; then
        echo -e "  ${CYAN}gNB IP:${NC} $GNB_IP"
    elif [ -n "$3" ] && [ "$3" != "none" ]; then
        echo -e "  ${CYAN}Extra:${NC} $(basename "$3")"
    else
        echo -e "  ${CYAN}Extra:${NC} (none)"
    fi
    echo ""
    read -p "Proceed? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ─── Template manipulation ────────────────────────────────────────────────────

replace_value_nested() {
    local pattern="$1" new_value="$2"
    if grep -E "[[:space:]]${pattern}[[:space:]]*=" "$OUTPUT_FILE" >/dev/null 2>&1; then
        sed -i.bak "s|\([[:space:]]${pattern}[[:space:]]*=[[:space:]]*\).*|\1${new_value};|" "$OUTPUT_FILE"
        return 0
    fi
    return 1
}

read_json_clean() {
    grep -v '^\s*//' "$1" | sed 's|//.*||' | sed 's|/\*.*\*/||' \
        | sed 's/:\s*\(-\?[0-9][0-9]*[Ll]\)\b/: "\1"/g'
}

extract_json_params() {
    local file="$1" category="$2"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Reading parameters from $category...${NC}"
    echo -e "${CYAN}File: $(basename "$file")${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    [ -f "$file" ] || { echo -e "${RED}ERROR: File does not exist!${NC}"; echo ""; return 1; }

    local clean_json keys jq_exit
    clean_json=$(read_json_clean "$file")
    [ -z "$clean_json" ] && { echo -e "${RED}ERROR: Empty JSON${NC}"; echo ""; return 1; }

    keys=$(echo "$clean_json" | jq -r 'keys[]' 2>&1)
    jq_exit=$?
    [ $jq_exit -ne 0 ] && { echo -e "${RED}ERROR: jq failed — $keys${NC}"; echo ""; return 1; }
    [ -z "$keys" ] && { echo -e "${RED}ERROR: No keys found${NC}"; echo ""; return 1; }

    local count=0 applied=0
    local applied_params=() applied_values=()
    local skipped_params=() skipped_values=()

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        count=$((count + 1))
        local value
        value=$(echo "$clean_json" | jq -r ".[\"$key\"]" 2>/dev/null)
        [ "$value" = "null" ] || [ -z "$value" ] && continue

        if echo "$clean_json" | jq -e ".[\"$key\"] | type == \"string\"" >/dev/null 2>&1; then
            if [[ "$value" =~ ^-?[0-9]+[Ll]$ ]]; then
                if replace_value_nested "$key" "$value"; then
                    applied=$((applied+1)); applied_params+=("$key"); applied_values+=("$value")
                else skipped_params+=("$key"); skipped_values+=("$value"); fi
            else
                if replace_value_nested "$key" "\"$value\""; then
                    applied=$((applied+1)); applied_params+=("$key"); applied_values+=("\"$value\"")
                else skipped_params+=("$key"); skipped_values+=("\"$value\""); fi
            fi
        else
            if replace_value_nested "$key" "$value"; then
                applied=$((applied+1)); applied_params+=("$key"); applied_values+=("$value")
            else skipped_params+=("$key"); skipped_values+=("$value"); fi
        fi
    done <<< "$keys"

    echo ""
    echo -e "${CYAN}📋 ALL PARAMETERS READ FROM JSON ($count total):${NC}"
    echo ""

    if [ ${#applied_params[@]} -gt 0 ]; then
        echo -e "${GREEN}✓ APPLIED ($applied parameters):${NC}"
        for i in "${!applied_params[@]}"; do
            printf "  ${GREEN}✓ %-38s${NC} = ${CYAN}%s${NC}\n" "${applied_params[$i]}" "${applied_values[$i]}"
        done
        echo ""
    fi

    if [ ${#skipped_params[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠ NOT IN TEMPLATE (${#skipped_params[@]} parameters):${NC}"
        for i in "${!skipped_params[@]}"; do
            printf "  ${YELLOW}⚠ %-38s${NC} = ${CYAN}%s${NC}\n" "${skipped_params[$i]}" "${skipped_values[$i]}"
        done
        echo ""
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Summary for $category: Applied ${GREEN}$applied${BLUE}/${count}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ─── Physical mode: additional options file ───────────────────────────────────

load_additional_options() {
    local file="$1"

    if [ -z "$file" ] || [ "$file" == "none" ]; then
        export USE_ADDITIONAL_OPTIONS=""
        echo "USE_ADDITIONAL_OPTIONS=" > .env.ue
        echo -e "${YELLOW}No additional options — USE_ADDITIONAL_OPTIONS is empty.${NC}"
        return 0
    fi

    [ -f "$file" ] || {
        echo -e "${RED}Error: Additional options file not found: $file${NC}"
        export USE_ADDITIONAL_OPTIONS=""; return 1
    }

    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}Loading additional options from: $(basename "$file")${NC}"
    echo -e "${CYAN}================================================${NC}"

    local clean_json
    clean_json=$(grep -v '^\s*//' "$file" | sed 's|//.*||' | sed 's|/\*.*\*/||')
    [ -z "$clean_json" ] && { echo -e "${RED}Error: Empty after cleaning.${NC}"; export USE_ADDITIONAL_OPTIONS=""; return 1; }
    echo "$clean_json" | jq empty 2>/dev/null || { echo -e "${RED}Error: Invalid JSON.${NC}"; export USE_ADDITIONAL_OPTIONS=""; return 1; }

    local invalid_keys
    invalid_keys=$(echo "$clean_json" | jq -r 'keys[] | select(startswith("-") | not)')
    if [ -n "$invalid_keys" ]; then
        echo -e "${RED}Error: All keys must start with '--' or '-'.${NC}"
        while IFS= read -r k; do echo -e "  ${RED}• $k${NC}"; done <<< "$invalid_keys"
        export USE_ADDITIONAL_OPTIONS=""; return 1
    fi

    local flags_str="" keys_list
    keys_list=$(echo "$clean_json" | jq -r 'keys[]')
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        local vtype vraw
        vtype=$(echo "$clean_json" | jq -r ".[\"$k\"] | type")
        vraw=$(echo "$clean_json"  | jq -r ".[\"$k\"]")
        case "$vtype" in
            "boolean") [ "$vraw" == "true" ] && flags_str="${flags_str} ${k}" ;;
            "null")    flags_str="${flags_str} ${k}" ;;
            "string"|"number") flags_str="${flags_str} ${k} ${vraw}" ;;
        esac
    done <<< "$keys_list"
    flags_str="${flags_str# }"

    export USE_ADDITIONAL_OPTIONS="$flags_str"
    echo "USE_ADDITIONAL_OPTIONS=${flags_str}" > .env.ue
    echo -e "${GREEN}Written .env.ue →${NC} ${CYAN}${flags_str}${NC}"
    echo ""
}

# ─── RFSim mode: auto-build USE_ADDITIONAL_OPTIONS from Cells JSON ────────────

build_rfsim_ue_options() {
    local cells_file="$1" gnb_ip="$2"

    local clean_json
    clean_json=$(read_json_clean "$cells_file")

    local rf_freq n_rb_dl numerology
    # Strip L/l suffix from rf_freq: the L is for libconfig (conf file) only,
    # not valid as a CLI argument to -C
    rf_freq=$(echo "$clean_json"   | jq -r '.rf_freq   // empty' | sed 's/[Ll]$//')
    n_rb_dl=$(echo "$clean_json"   | jq -r '.N_RB_DL   // empty')
    numerology=$(echo "$clean_json" | jq -r '.numerology // empty')

    # -E is USRP hardware only (3/4 sampling rate reduction), not needed for rfsim
    local flags="--rfsim"
    [ -n "$n_rb_dl"    ] && flags="$flags -r $n_rb_dl"
    [ -n "$numerology" ] && flags="$flags --numerology $numerology"
    [ -n "$rf_freq"    ] && flags="$flags -C $rf_freq"
    flags="$flags --rfsimulator.[0].serveraddr $gnb_ip"

    echo "$flags"
}

# ─── Directory / template discovery ──────────────────────────────────────────

find_confs_dir() {
    for dir in "./" "../" "../../"; do
        [ -d "${dir}confs" ] && echo "${dir}confs" && return 0
    done
    return 1
}

find_template() {
    local t="ue_template.conf"
    [ -f "./$t" ]           && echo "./$t"           && return 0
    [ -f "${CONF_DIR}/$t" ] && echo "${CONF_DIR}/$t" && return 0
    [ -f "../$t" ]          && echo "../$t"           && return 0
    return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────

display_header

CONF_DIR=$(find_confs_dir) || {
    echo -e "${RED}Error: 'confs' directory not found.${NC}"
    echo "Please run this script from the project directory."
    exit 1
}
echo -e "${GREEN}Found configuration directory:${NC} $CONF_DIR"
echo ""

TEMPLATE_FILE=$(find_template) || {
    echo -e "${RED}Error: ue_template.conf not found.${NC}"
    exit 1
}
echo -e "${GREEN}Found template file:${NC} $TEMPLATE_FILE"
echo ""

# ── Load last config or ask for new ──────────────────────────────────────────
USE_LAST_CONFIG=false
if load_last_config; then
    if show_last_config_menu; then
        USE_LAST_CONFIG=true
    fi
fi

if [ "$USE_LAST_CONFIG" = false ]; then

    # Step 1 — Mode
    MODE=$(select_mode)
    GNB_IP="${GNB_IP:-172.22.0.25}"
    ADDITIONAL_FILE="none"
    echo ""
    echo -e "${CYAN}Mode: $(mode_label "$MODE")${NC}"
    echo ""

    # Step 2 — File selection
    echo -e "${GREEN}Select configuration files${NC}"
    echo ""

    if [ "$MODE" == "rfsim" ]; then
        RU_FILE="${CONF_DIR}/RUs/RFSim_UE.json"
        if [ ! -f "$RU_FILE" ]; then
            echo -e "${RED}Error: RFSim_UE.json not found in ${CONF_DIR}/RUs/${NC}"
            exit 1
        fi
        echo -e "  ${CYAN}RU:${NC} RFSim_UE.json (auto-selected for RFSimulator)"
        echo ""

        CELLS_FILE=$(select_file "${CONF_DIR}/UE/Cells" "Cells configuration") || exit 1
        echo ""

        # Ask for gNB IP
        echo -e "${YELLOW}gNB IP address for RFSimulator connection:${NC}"
        read -p "  gNB IP [172.22.0.25]: " _gnb_ip
        GNB_IP="${_gnb_ip:-172.22.0.25}"
        echo ""

    else
        RU_FILE=$(select_file "${CONF_DIR}/RUs" "RU configuration" "*UE*.json") || exit 1
        echo ""
        CELLS_FILE=$(select_file "${CONF_DIR}/UE/Cells" "Cells configuration") || exit 1
        echo ""
        ADDITIONAL_FILE=$(select_additional_options_file \
            "${CONF_DIR}/UE/UE_additional_flags")
        echo ""
    fi

    confirm_selection "$RU_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE" || {
        echo -e "${YELLOW}Configuration cancelled.${NC}"; exit 0
    }

    save_last_config "$MODE" "$RU_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE" "$GNB_IP"
fi

# ── Output file ───────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Output options:${NC}"
echo -e "  1) Create new file (default)"
echo -e "  2) Overwrite template (keep backup)"
echo ""
read -p "Choose option [1]: " output_option
output_option="${output_option:-1}"

if [ "$output_option" == "2" ]; then
    BACKUP_FILE="${TEMPLATE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$TEMPLATE_FILE" "$BACKUP_FILE"
    echo -e "${GREEN}Created backup:${NC} $BACKUP_FILE"
    OUTPUT_FILE="$TEMPLATE_FILE"
else
    read -p "Enter output filename [ue_configured.conf]: " OUTPUT_FILE
    OUTPUT_FILE="${OUTPUT_FILE:-ue_configured.conf}"
fi

echo ""
echo -e "${GREEN}Processing configuration...${NC}"
echo ""

[ "$TEMPLATE_FILE" != "$OUTPUT_FILE" ] && cp "$TEMPLATE_FILE" "$OUTPUT_FILE" \
    || echo -e "${BLUE}Working directly on template (backup already created)${NC}"
echo ""

# ── Apply JSON files ──────────────────────────────────────────────────────────
extract_json_params "$RU_FILE"    "RU"
extract_json_params "$CELLS_FILE" "Cells"
rm -f "${OUTPUT_FILE}.bak"

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✓ Template patching complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${CYAN}Output file:${NC} $OUTPUT_FILE"
echo ""

# ── Mode-specific env config ──────────────────────────────────────────────────

if [ "$MODE" == "rfsim" ]; then
    # Auto-build USE_ADDITIONAL_OPTIONS from Cells JSON + gNB IP
    rfsim_opts=$(build_rfsim_ue_options "$CELLS_FILE" "$GNB_IP")
    export USE_ADDITIONAL_OPTIONS="$rfsim_opts"
    echo "USE_ADDITIONAL_OPTIONS=${rfsim_opts}" > .env.ue

    echo -e "${GREEN}Written .env.ue (RFSim flags):${NC}"
    echo -e "  ${CYAN}${rfsim_opts}${NC}"

    START_SERVICE="oai-nr-ue-rfsim"
else
    # Physical: load additional options file
    load_additional_options "$ADDITIONAL_FILE"
    START_SERVICE="oai-nr-ue"
fi

echo ""

# Show USE_ADDITIONAL_OPTIONS status
if [ -n "$USE_ADDITIONAL_OPTIONS" ]; then
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} set (${#USE_ADDITIONAL_OPTIONS} chars)"
else
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} (empty)"
fi
echo ""

# ── Start container ───────────────────────────────────────────────────────────
read -p "Do you want to start the UE container now? (y/n): " start_container
if [[ "$start_container" =~ ^[Yy]$ ]]; then
    if [ "$OUTPUT_FILE" != "$TEMPLATE_FILE" ]; then
        echo -e "${YELLOW}⚠ docker-compose mounts ue_template.conf — ensure the output file is the template or update the volume mount.${NC}"
    fi
    echo -e "${CYAN}Starting service '${START_SERVICE}'...${NC}"
    if $DOCKER_COMPOSE -f docker-compose_ran.yaml up "$START_SERVICE"; then
        echo -e "${GREEN}✓ Container exited.${NC}"
    else
        echo -e "${RED}✗ Failed to start container.${NC}"
    fi
fi
echo ""
