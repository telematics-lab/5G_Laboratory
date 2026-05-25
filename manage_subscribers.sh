#!/bin/bash

# Open5GS subscriber management — add or update via MongoDB
# Usage:
#   ./manage_subscribers.sh                                        → interactive menu
#   ./manage_subscribers.sh add    <imsi> <key> <opc> [dnn] [sst] [static_ip]
#   ./manage_subscribers.sh update <imsi> <key> <opc> [dnn] [sst] [static_ip]
#   ./manage_subscribers.sh delete <imsi>
#   ./manage_subscribers.sh list
#   ./manage_subscribers.sh from-json <path/to/sim.json>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MONGO_CONTAINER="mongo"
DB="open5gs"

# ─── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    echo -e "${CYAN}Usage:${NC}"
    echo -e "  $0                                                            → interactive menu"
    echo -e "  $0 add    <imsi> <key> <opc> [dnn=oai] [sst=1] [static_ip]"
    echo -e "  $0 update <imsi> <key> <opc> [dnn=oai] [sst=1] [static_ip]"
    echo -e "  $0 delete <imsi>"
    echo -e "  $0 list"
    echo -e "  $0 from-json <path/to/sim.json>"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  $0 add 001010000000001 fec86ba6eb707ed08905757b1bb44b8f C42449363BBAD02B66D16BC975D77CC1"
    echo -e "  $0 add 001010000000002 fec86ba6eb707ed08905757b1bb44b8f C42449363BBAD02B66D16BC975D77CC1 internet 1 10.45.0.5"
    echo -e "  $0 from-json confs/UE/SIM/001010000000001.json"
    exit 1
}

mongosh_exec() {
    docker exec -i "$MONGO_CONTAINER" mongosh "$DB" --quiet --eval "$1"
}

# Returns 0 if <ip> is within <subnet/prefix> (e.g. 192.168.100.0/24)
ip_in_subnet() {
    local ip="$1" subnet="$2"
    local net="${subnet%/*}" prefix="${subnet#*/}"
    local ip_int net_int mask
    IFS=. read -r a b c d <<< "$ip";   ip_int=$(( (a<<24)|(b<<16)|(c<<8)|d ))
    IFS=. read -r a b c d <<< "$net";  net_int=$(( (a<<24)|(b<<16)|(c<<8)|d ))
    mask=$(( 0xFFFFFFFF << (32-prefix) & 0xFFFFFFFF ))
    [ $(( ip_int & mask )) -eq $(( net_int & mask )) ]
}

# Warn if static_ip is outside the UPF subnet for the chosen DNN
check_ip_in_upf_subnet() {
    local ip="$1" dnn="$2"
    local env_file=".env.cn"
    [ -f "$env_file" ] || return 0

    local subnet=""
    case "$dnn" in
        oai|internet) subnet=$(grep -E '^UE_IPV4_INTERNET=' "$env_file" | cut -d= -f2 | tr -d ' ') ;;
        ims)          subnet=$(grep -E '^UE_IPV4_IMS='      "$env_file" | cut -d= -f2 | tr -d ' ') ;;
    esac

    [ -z "$subnet" ] && return 0
    if ! ip_in_subnet "$ip" "$subnet"; then
        echo -e "${YELLOW}⚠ Warning: $ip is outside the UPF subnet $subnet for DNN '$dnn'.${NC}"
        echo -e "${YELLOW}  The UE will not receive this IP — check .env.cn.${NC}"
    fi
}

check_mongo() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
        echo -e "${RED}Error: container '${MONGO_CONTAINER}' is not running.${NC}"
        exit 1
    fi
}

display_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}    Open5GS Subscriber Manager${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

prompt() {
    # prompt <label> <default> <var_name> [regex] [error_msg]
    local label="$1" default="$2" var_name="$3" pattern="${4:-}" errmsg="${5:-Invalid value.}"
    # A pattern that contains ^$ explicitly allows empty input (optional field)
    local allow_empty=false
    [[ "$pattern" == *'^$'* ]] && allow_empty=true
    local input
    while true; do
        if [ -n "$default" ]; then
            read -p "  $label [$default]: " input
            input="${input:-$default}"
        else
            read -p "  $label: " input
            if [ -z "$input" ] && [ "$allow_empty" = false ]; then
                echo -e "  ${RED}Required.${NC}"
                continue
            fi
        fi
        if [ -n "$pattern" ] && [[ ! "$input" =~ $pattern ]]; then
            echo -e "  ${RED}${errmsg}${NC}"
            continue
        fi
        break
    done
    printf -v "$var_name" '%s' "$input"
}

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# ─── Operations ───────────────────────────────────────────────────────────────

do_list() {
    echo -e "${CYAN}Subscribers in Open5GS:${NC}"
    echo ""
    mongosh_exec "
        let subs = db.subscribers.find(
            {},
            { imsi:1, 'security.k':1, 'security.opc':1, slice:1, _id:0 }
        ).toArray();
        if (subs.length === 0) {
            print('  (no subscribers found)');
        } else {
            subs.forEach((s, i) => {
                print('  [' + (i+1) + '] IMSI : ' + s.imsi);
                print('       K   : ' + s.security.k);
                print('       OPc : ' + s.security.opc);
                if (s.slice && s.slice.length > 0) {
                    s.slice.forEach(sl => {
                        if (sl.session && sl.session.length > 0) {
                            let sess = sl.session[0];
                            let ip = (sess.ue && sess.ue.ipv4) ? sess.ue.ipv4 : 'dynamic';
                            print('       SST : ' + sl.sst + '   DNN: ' + sess.name + '   IP: ' + ip);
                        }
                    });
                }
                print('');
            });
            print('  Total: ' + subs.length + ' subscriber(s)');
        }
    "
}

do_delete() {
    local imsi="$1"
    [ -z "$imsi" ] && { echo -e "${RED}Error: IMSI required.${NC}"; usage; }

    local result
    result=$(mongosh_exec "
        let r = db.subscribers.deleteOne({ imsi: '$imsi' });
        print(r.deletedCount);
    ")
    if [ "$result" = "1" ]; then
        echo -e "${GREEN}✓ Subscriber $imsi deleted.${NC}"
    else
        echo -e "${YELLOW}⚠ Subscriber $imsi not found.${NC}"
    fi
}

do_upsert() {
    local imsi="$1"
    local key="$2"
    local opc="$3"
    local dnn="${4:-oai}"
    local sst="${5:-1}"
    local static_ip="${6:-}"

    [ -z "$imsi" ] || [ -z "$key" ] || [ -z "$opc" ] && {
        echo -e "${RED}Error: imsi, key and opc are required.${NC}"; usage
    }

    [[ ${#key} -ne 32 ]]          && echo -e "${YELLOW}⚠ Warning: key should be 32 hex chars (got ${#key})${NC}"
    [[ ${#opc} -ne 32 ]]          && echo -e "${YELLOW}⚠ Warning: opc should be 32 hex chars (got ${#opc})${NC}"
    [[ ! "$imsi" =~ ^[0-9]{15}$ ]] && echo -e "${YELLOW}⚠ Warning: imsi should be 15 digits (got '${imsi}')${NC}"
    if [ -n "$static_ip" ] && [[ ! "$static_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${YELLOW}⚠ Warning: static_ip does not look like a valid IPv4 address ('${static_ip}')${NC}"
    fi
    [ -n "$static_ip" ] && check_ip_in_upf_subnet "$static_ip" "$dnn"

    # Build optional static IP field for the session object
    local ue_ip_field=""
    [ -n "$static_ip" ] && ue_ip_field="ue: { ipv4: '$static_ip' },"

    local subscriber_doc="{
        imsi: '$imsi',
        msisdn: [],
        imeisv: [],
        security: {
            k: '$key',
            op: null,
            opc: '$opc',
            amf: '8000'
        },
        ambr: {
            downlink: { value: 1, unit: 3 },
            uplink:   { value: 1, unit: 3 }
        },
        slice: [{
            sst: $sst,
            default_indicator: true,
            session: [{
                name: '$dnn',
                type: 3,
                $ue_ip_field
                qos: {
                    index: 9,
                    arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 }
                },
                ambr: {
                    downlink: { value: 1, unit: 3 },
                    uplink:   { value: 1, unit: 3 }
                }
            }]
        }],
        access_restriction_data: 32,
        subscriber_status: 0,
        network_access_mode: 0,
        subscribed_rau_tau_timer: 12,
        __v: 0
    }"

    local result
    result=$(mongosh_exec "
        let exists = db.subscribers.countDocuments({ imsi: '$imsi' });
        let r = db.subscribers.replaceOne(
            { imsi: '$imsi' },
            $subscriber_doc,
            { upsert: true }
        );
        print(exists + ':' + (r.upsertedCount + r.modifiedCount));
    ")

    local was_existing="${result%%:*}"
    local changed="${result##*:}"

    local ip_info=""
    [ -n "$static_ip" ] && ip_info=", IP=$static_ip" || ip_info=", IP=dynamic"

    if [ "$changed" = "1" ]; then
        if [ "$was_existing" = "0" ]; then
            echo -e "${GREEN}✓ Subscriber $imsi added (DNN=$dnn, SST=$sst${ip_info}).${NC}"
        else
            echo -e "${GREEN}✓ Subscriber $imsi updated (DNN=$dnn, SST=$sst${ip_info}).${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No changes made to $imsi.${NC}"
    fi
}

do_from_json() {
    local file="$1"
    [ -z "$file" ] && { echo -e "${RED}Error: path to JSON file required.${NC}"; usage; }
    [ -f "$file" ]  || { echo -e "${RED}Error: file not found: $file${NC}"; exit 1; }

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required but not installed.${NC}"
        exit 1
    fi

    local imsi key opc dnn sst
    imsi=$(jq -r '.imsi // empty' "$file")
    key=$(jq -r '.key  // empty' "$file")
    opc=$(jq -r '.opc  // empty' "$file")
    dnn=$(jq -r 'if .dnn then .dnn elif (.pdu_sessions | type) == "array" then .pdu_sessions[0].dnn elif (.pdu_sessions | type) == "string" then (.pdu_sessions | capture("dnn = \"(?P<d>[^\"]+)\"") | .d) else "oai" end // "oai"' "$file" 2>/dev/null)
    sst=$(jq -r 'if .sst then .sst elif (.pdu_sessions | type) == "array" then .pdu_sessions[0].nssai_sst elif (.pdu_sessions | type) == "string" then (.pdu_sessions | capture("nssai_sst = (?P<s>[0-9]+)") | .s) else "1" end // "1"' "$file" 2>/dev/null)

    [ -z "$imsi" ] && { echo -e "${RED}Error: 'imsi' not found in $file${NC}"; exit 1; }
    [ -z "$key"  ] && { echo -e "${RED}Error: 'key' not found in $file${NC}";  exit 1; }
    [ -z "$opc"  ] && { echo -e "${RED}Error: 'opc' not found in $file${NC}";  exit 1; }

    echo -e "${CYAN}Loaded from $(basename "$file"):${NC}"
    echo -e "  IMSI: $imsi  DNN: ${dnn:-oai}  SST: ${sst:-1}"
    echo ""
    do_upsert "$imsi" "$key" "$opc" "${dnn:-oai}" "${sst:-1}"
}

# ─── Interactive menu ─────────────────────────────────────────────────────────

# Fetches current subscriber fields from MongoDB into caller variables.
# Sets: _CUR_KEY _CUR_OPC _CUR_DNN _CUR_SST _CUR_IP
fetch_subscriber() {
    local imsi="$1"
    local raw
    raw=$(mongosh_exec "
        let s = db.subscribers.findOne({ imsi: '$imsi' },
            { 'security.k':1, 'security.opc':1, slice:1, _id:0 });
        if (!s) { print('NOT_FOUND'); }
        else {
            let sess = (s.slice && s.slice[0] && s.slice[0].session && s.slice[0].session[0])
                       ? s.slice[0].session[0] : {};
            print([
                s.security.k,
                s.security.opc,
                sess.name  || 'oai',
                s.slice && s.slice[0] ? s.slice[0].sst : 1,
                (sess.ue && sess.ue.ipv4) ? sess.ue.ipv4 : ''
            ].join('|'));
        }
    ")
    if [ "$raw" = "NOT_FOUND" ] || [ -z "$raw" ]; then
        return 1
    fi
    IFS='|' read -r _CUR_KEY _CUR_OPC _CUR_DNN _CUR_SST _CUR_IP <<< "$raw"
    return 0
}

menu_add() {
    display_header
    echo -e "${BLUE}Add Subscriber${NC}"
    echo ""

    local IMSI KEY OPC DNN SST STATIC_IP
    prompt "IMSI (15 digits)"          ""     IMSI      '^[0-9]{15}$'                       "Must be exactly 15 digits."
    prompt "K   (32 hex)"              ""     KEY       '^[0-9a-fA-F]{32}$'                 "Must be exactly 32 hex characters."
    prompt "OPc (32 hex)"             ""     OPC       '^[0-9a-fA-F]{32}$'                 "Must be exactly 32 hex characters."
    prompt "DNN"                       "oai"  DNN
    prompt "SST"                       "1"    SST       '^[0-9]+$'                           "Must be a number."
    prompt "Static IP (Enter=dynamic)" ""     STATIC_IP '^$|^([0-9]{1,3}\.){3}[0-9]{1,3}$' "Must be a valid IPv4 address (or empty)."

    echo ""
    do_upsert "$IMSI" "$KEY" "$OPC" "$DNN" "$SST" "$STATIC_IP"
    press_enter
}

menu_update() {
    display_header
    echo -e "${BLUE}Update Subscriber${NC}"
    echo ""
    do_list
    echo ""

    local IMSI
    prompt "IMSI to update" "" IMSI '^[0-9]{15}$' "Must be exactly 15 digits."
    echo ""

    local _CUR_KEY _CUR_OPC _CUR_DNN _CUR_SST _CUR_IP
    if ! fetch_subscriber "$IMSI"; then
        echo -e "${RED}Subscriber $IMSI not found.${NC}"
        press_enter
        return
    fi

    echo -e "${CYAN}Current values shown as defaults — press Enter to keep.${NC}"
    echo ""

    local KEY OPC DNN SST STATIC_IP
    prompt "K   (32 hex)"              "$_CUR_KEY" KEY       '^[0-9a-fA-F]{32}$'                 "Must be exactly 32 hex characters."
    prompt "OPc (32 hex)"             "$_CUR_OPC" OPC       '^[0-9a-fA-F]{32}$'                 "Must be exactly 32 hex characters."
    prompt "DNN"                       "$_CUR_DNN" DNN
    prompt "SST"                       "$_CUR_SST" SST       '^[0-9]+$'                           "Must be a number."
    local ip_hint="Enter=keep"
    [ -n "$_CUR_IP" ] && ip_hint="Enter=keep, \"-\"=remove"
    prompt "Static IP ($ip_hint)" "$_CUR_IP" STATIC_IP \
        '^$|^-$|^([0-9]{1,3}\.){3}[0-9]{1,3}$' "Must be a valid IPv4 address, \"-\" to remove, or empty."
    [ "$STATIC_IP" = "-" ] && STATIC_IP=""

    echo ""
    do_upsert "$IMSI" "$KEY" "$OPC" "$DNN" "$SST" "$STATIC_IP"
    press_enter
}

menu_delete() {
    display_header
    echo -e "${BLUE}Delete Subscriber${NC}"
    echo ""
    do_list
    echo ""
    local IMSI confirm
    prompt "IMSI to delete" "" IMSI
    echo ""
    read -p "  Confirm delete '$IMSI'? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        do_delete "$IMSI"
    else
        echo -e "${YELLOW}Cancelled.${NC}"
    fi
    press_enter
}

menu_list() {
    display_header
    do_list
    press_enter
}

menu_from_json() {
    display_header
    echo -e "${BLUE}Import from JSON file${NC}"
    echo ""

    # Show available SIM JSON files if any
    local sim_dir="confs/UE/SIM"
    if [ -d "$sim_dir" ]; then
        local files=()
        while IFS= read -r f; do files+=("$f"); done \
            < <(find "$sim_dir" -maxdepth 1 -name "*.json" | sort)

        if [ ${#files[@]} -gt 0 ]; then
            echo -e "${CYAN}Available SIM files:${NC}"
            for i in "${!files[@]}"; do
                printf "  ${GREEN}%2d)${NC} %s\n" $((i+1)) "${files[$i]}"
            done
            echo -e "   ${GREEN}0)${NC} Enter path manually"
            echo ""
            local sel
            read -p "  Select (0-${#files[@]}): " sel
            if [[ "$sel" =~ ^[1-9][0-9]*$ ]] && [ "$sel" -le "${#files[@]}" ]; then
                echo ""
                do_from_json "${files[$((sel-1))]}"
                press_enter
                return
            fi
        fi
    fi

    local FILE
    prompt "JSON file path" "" FILE
    echo ""
    do_from_json "$FILE"
    press_enter
}

main_menu() {
    while true; do
        display_header
        echo -e "${BLUE}Select operation:${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} List subscribers"
        echo -e "  ${GREEN}2)${NC} Add subscriber"
        echo -e "  ${GREEN}3)${NC} Update subscriber"
        echo -e "  ${GREEN}4)${NC} Delete subscriber"
        echo -e "  ${GREEN}5)${NC} Import from JSON file"
        echo -e "  ${GREEN}0)${NC} Exit"
        echo ""
        read -p "Choose option: " choice
        case "$choice" in
            1) menu_list      ;;
            2) menu_add       ;;
            3) menu_update    ;;
            4) menu_delete    ;;
            5) menu_from_json ;;
            0) echo ""; exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

check_mongo

case "${1:-}" in
    add|update)   do_upsert "$2" "$3" "$4" "${5:-oai}" "${6:-1}" "${7:-}" ;;
    delete)       do_delete "$2" ;;
    list)         do_list ;;
    from-json)    do_from_json "$2" ;;
    "")           main_menu ;;
    *)            usage ;;
esac
