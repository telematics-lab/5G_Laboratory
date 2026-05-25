#!/bin/bash

# Script to configure gnb_template.conf with values from JSON files
# Terrestrial gNB — supports Physical (USRP) and RFSimulator modes

# set -e  # Disabled for better error visibility

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LAST_CONFIG_FILE=".gnb_last_config"

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
    echo -e "${CYAN}    gNB Configuration Tool - Terrestrial${NC}"
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
    local mode="$1" ru_file="$2" cells_file="$3" additional_file="${4:-none}"
    cat > "$LAST_CONFIG_FILE" << EOF
MODE=$mode
RU_FILE=$ru_file
CELLS_FILE=$cells_file
ADDITIONAL_FILE=$additional_file
EOF
    echo -e "${GREEN}Configuration saved for next time.${NC}"
}

load_last_config() {
    [ -f "$LAST_CONFIG_FILE" ] || return 1
    source "$LAST_CONFIG_FILE"
    MODE="${MODE:-physical}"
    ADDITIONAL_FILE="${ADDITIONAL_FILE:-none}"
    if [ -f "$RU_FILE" ] && [ -f "$CELLS_FILE" ]; then return 0; fi
    echo -e "${YELLOW}Last configuration files no longer exist.${NC}"
    return 1
}

show_last_config_menu() {
    echo -e "${BLUE}Last used configuration:${NC}"
    echo -e "  ${CYAN}Mode:${NC}  $(mode_label "$MODE")"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$RU_FILE")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$CELLS_FILE")"
    if [ "$MODE" != "rfsim" ] && [ -n "$ADDITIONAL_FILE" ] && [ "$ADDITIONAL_FILE" != "none" ]; then
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
        echo -e "${RED}Error: Directory not found: $dir${NC}" >&2
        return 1
    fi

    while IFS= read -r f; do files+=("$f"); done \
        < <(find "$dir" -maxdepth 2 -name "$pattern" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Error: No JSON files found in $dir${NC}" >&2
        return 1
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

# ─── Physical mode: additional options file ───────────────────────────────────

load_additional_options() {
    local file="$1"

    if [ -z "$file" ] || [ "$file" == "none" ]; then
        export USE_ADDITIONAL_OPTIONS=""
        echo "USE_ADDITIONAL_OPTIONS=" > .env.gnb
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
    echo "USE_ADDITIONAL_OPTIONS=${flags_str}" > .env.gnb
    echo -e "${GREEN}Written .env.gnb →${NC} ${CYAN}${flags_str}${NC}"
    echo ""
}

confirm_selection() {
    echo ""
    echo -e "${YELLOW}Selected configurations:${NC}"
    echo -e "  ${CYAN}Mode:${NC}  $(mode_label "$MODE")"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$1")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$2")"
    if [ "$MODE" != "rfsim" ] && [ -n "$3" ] && [ "$3" != "none" ]; then
        echo -e "  ${CYAN}Extra:${NC} $(basename "$3")"
    else
        echo -e "  ${CYAN}Extra:${NC} (none)"
    fi
    echo ""
    read -p "Proceed? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ─── Template manipulation ────────────────────────────────────────────────────

replace_value() {
    local pattern="$1" new_value="$2"
    if grep -E "^[[:space:]]*${pattern}[[:space:]]*=" "$OUTPUT_FILE" >/dev/null 2>&1; then
        sed -i.bak "s|^\([[:space:]]*${pattern}[[:space:]]*=[[:space:]]*\).*|\1${new_value};|" "$OUTPUT_FILE"
        return 0
    fi
    return 1
}

read_json_clean() {
    grep -v '^\s*//' "$1" | sed 's|//.*||' | sed 's|/\*.*\*/||'
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
            if replace_value "$key" "\"$value\""; then
                applied=$((applied+1)); applied_params+=("$key"); applied_values+=("\"$value\"")
            else
                skipped_params+=("$key"); skipped_values+=("\"$value\"")
            fi
        else
            if replace_value "$key" "$value"; then
                applied=$((applied+1)); applied_params+=("$key"); applied_values+=("$value")
            else
                skipped_params+=("$key"); skipped_values+=("$value")
            fi
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

# ─── Auto-sync from .env.cn ──────────────────────────────────────────────────
# Reads AMF_IP, MCC, MNC, TAC from .env.cn and patches them into the output conf.
# Called after JSON extraction so it always reflects the current CN configuration.

apply_env_cn() {
    # Locate .env.cn starting from current dir upward
    local env_file=""
    for d in "./" "../" "../../"; do
        if [ -f "${d}.env.cn" ]; then env_file="${d}.env.cn"; break; fi
    done

    if [ -z "$env_file" ]; then
        echo -e "${YELLOW}⚠ .env.cn not found — skipping CN parameter sync${NC}"
        echo ""
        return 1
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Syncing CN parameters from $(basename "$env_file")...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Parse values (strip inline comments and whitespace)
    local amf_ip mcc mnc tac
    amf_ip=$(grep -E '^AMF_IP='            "$env_file" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' \t')
    mcc=$(   grep -E '^MCC='               "$env_file" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' \t')
    mnc=$(   grep -E '^MNC='               "$env_file" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' \t')
    tac=$(   grep -E '^TAC='               "$env_file" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d ' \t')

    local applied=0

    # AMF IP — nested structure: amf_ip_address = ({ ipv4 = "..."; });
    if [ -n "$amf_ip" ]; then
        if sed -i.bak "s|\(amf_ip_address = ({ ipv4 = \)\"[^\"]*\"|\1\"${amf_ip}\"|" "$OUTPUT_FILE" \
           && grep -q "\"${amf_ip}\"" "$OUTPUT_FILE"; then
            echo -e "  ${GREEN}✓ AMF_IP             ${NC}= ${CYAN}${amf_ip}${NC}"
            applied=$((applied+1))
        else
            echo -e "  ${YELLOW}⚠ AMF_IP: pattern not found in template${NC}"
        fi
    fi

    # MCC — inline in plmn_list: mcc = 001;
    if [ -n "$mcc" ]; then
        if sed -i.bak "s|\(plmn_list.*mcc = \)[0-9]*|\1${mcc}|" "$OUTPUT_FILE"; then
            echo -e "  ${GREEN}✓ MCC                ${NC}= ${CYAN}${mcc}${NC}"
            applied=$((applied+1))
        else
            echo -e "  ${YELLOW}⚠ MCC: pattern not found in template${NC}"
        fi
    fi

    # MNC — inline in plmn_list: mnc = 01;
    if [ -n "$mnc" ]; then
        if sed -i.bak "s|\(plmn_list.*mcc = [0-9]*; mnc = \)[0-9]*|\1${mnc}|" "$OUTPUT_FILE"; then
            echo -e "  ${GREEN}✓ MNC                ${NC}= ${CYAN}${mnc}${NC}"
            applied=$((applied+1))
        else
            echo -e "  ${YELLOW}⚠ MNC: pattern not found in template${NC}"
        fi
    fi

    # TAC — standalone line: tracking_area_code = 1;
    if [ -n "$tac" ]; then
        if replace_value "tracking_area_code" "$tac"; then
            echo -e "  ${GREEN}✓ TAC                ${NC}= ${CYAN}${tac}${NC}"
            applied=$((applied+1))
        else
            echo -e "  ${YELLOW}⚠ TAC: pattern not found in template${NC}"
        fi
    fi

    rm -f "${OUTPUT_FILE}.bak"
    echo ""
    echo -e "${BLUE}CN sync: applied ${GREEN}${applied}${BLUE} parameters from .env.cn${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ─── Directory / template discovery ──────────────────────────────────────────

find_confs_dir() {
    for dir in "./" "../" "../../"; do
        [ -d "${dir}confs" ] && echo "${dir}confs" && return 0
    done
    return 1
}

find_template() {
    local t="gnb_template.conf"
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
    echo -e "${RED}Error: gnb_template.conf not found.${NC}"
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
    echo ""
    echo -e "${CYAN}Mode: $(mode_label "$MODE")${NC}"
    echo ""

    # Step 2 — File selection
    echo -e "${GREEN}Select configuration files${NC}"
    echo ""

    if [ "$MODE" == "rfsim" ]; then
        RU_FILE="${CONF_DIR}/RUs/RFSim_gNB.json"
        if [ ! -f "$RU_FILE" ]; then
            echo -e "${RED}Error: RFSim_gNB.json not found in ${CONF_DIR}/RUs/${NC}"
            exit 1
        fi
        echo -e "  ${CYAN}RU:${NC} RFSim_gNB.json (auto-selected for RFSimulator)"
        echo ""
    else
        RU_FILE=$(select_file "${CONF_DIR}/RUs" "RU configuration" "*gNB*.json") || exit 1
        echo ""
    fi

    CELLS_FILE=$(select_file "${CONF_DIR}/gNB/Cells" "Cells configuration") || exit 1
    echo ""

    if [ "$MODE" != "rfsim" ]; then
        ADDITIONAL_FILE=$(select_additional_options_file \
            "${CONF_DIR}/gNB/gNB_additional_flags")
        echo ""
    else
        ADDITIONAL_FILE="none"
    fi

    confirm_selection "$RU_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE" || {
        echo -e "${YELLOW}Configuration cancelled.${NC}"; exit 0
    }

    save_last_config "$MODE" "$RU_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE"
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
    read -p "Enter output filename [gnb_configured.conf]: " OUTPUT_FILE
    OUTPUT_FILE="${OUTPUT_FILE:-gnb_configured.conf}"
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

# ── Sync CN parameters from .env.cn ───────────────────────────────────────────
apply_env_cn

rm -f "${OUTPUT_FILE}.bak"

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✓ Template patching complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${CYAN}Output file:${NC} $OUTPUT_FILE"
echo ""

# ── Mode-specific env config ──────────────────────────────────────────────────
if [ "$MODE" == "rfsim" ]; then
    # --rfsimulator.[0].serveraddr server  → gNB listens (server mode)
    {
        echo "USE_ADDITIONAL_OPTIONS=--rfsim --rfsimulator.[0].serveraddr server"
    } > .env.gnb
    echo -e "${GREEN}Written .env.gnb:${NC}"
    echo -e "  ${CYAN}USE_ADDITIONAL_OPTIONS=--rfsim --rfsimulator.[0].serveraddr server${NC}"

    START_SERVICE="oai-gnb-rfsim"

else
    # Physical: load additional options file
    load_additional_options "$ADDITIONAL_FILE"
    START_SERVICE="oai-gnb"
fi

echo ""
if [ -n "$USE_ADDITIONAL_OPTIONS" ]; then
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} set (${#USE_ADDITIONAL_OPTIONS} chars)"
else
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} (empty)"
fi
echo ""

# ── Start container ───────────────────────────────────────────────────────────
read -p "Do you want to start the gNB container now? (y/n): " start_container
if [[ "$start_container" =~ ^[Yy]$ ]]; then
    if [ "$OUTPUT_FILE" != "$TEMPLATE_FILE" ]; then
        echo -e "${YELLOW}⚠ docker-compose mounts gnb_template.conf — ensure the output file is the template or update the volume mount.${NC}"
    fi
    echo -e "${CYAN}Starting service '${START_SERVICE}'...${NC}"
    if $DOCKER_COMPOSE -f docker-compose_ran.yaml up "$START_SERVICE"; then
        echo -e "${GREEN}✓ Container exited.${NC}"
    else
        echo -e "${RED}✗ Failed to start container.${NC}"
    fi
fi
echo ""
