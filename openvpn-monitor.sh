#!/bin/bash

set -e

usage()
{
    echo "Usage: $0 --<parameter>[=<value>]"
    echo ""
    echo "Required:"
    echo "--status-log=<value>       - Path to openvpn status log created by openvpn itself, input"
    echo "                             (e.g. /etc/openvpn/server/openvpn-status.log)"
    echo "--stats=<value>            - Path to monitoring stats created by this script, output"
    echo "                             (e.g. /etc/openvpn/server/openvpn-custom-monitor-stats.log)"
    echo ""
    echo "Optional:"
    echo "--timeout=<value>          - Timeout in seconds after which to process stats (default: 60)"
    echo "--log=<value>              - Path to log of this script, output (default: stats + .ovpn_monitor.debug_log)"
}

# Path to openvpn status log created by openvpn itself (e.g. /etc/openvpn/server/openvpn-status.log)
STATUS_LOG_PATH=""
# Path to monitoring stats created by this script (e.g. /etc/openvpn/server/openvpn-custom-monitor-stats.log)
STATS_MONITOR_PATH=""
# Timeout in seconds after which to process stats
TIMEOUT=""
# Path to log of this script (e.g. /etc/openvpn/server/openvpn-custom-monitor-stats.log.ovpn_monitor.debug_log)
LOG_PATH=""

for i in "$@"
do
    if [ $# -le 0 ]; then
        break
    fi

    case $i in
        -h|--help)
            usage
            exit 0
            ;;
        --status-log=*)
            STATUS_LOG_PATH=${i#*=}
            ;;
        --stats=*)
            STATS_MONITOR_PATH=${i#*=}
            ;;
        --timeout=*)
            TIMEOUT=${i#*=}
            ;;
        --log=*)
            LOG_PATH=${i#*=}
            ;;
        *)
            echo "Unknown option: <$i>"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ "${STATUS_LOG_PATH}" == "" ]]; then
    echo "Specify path to status log of openvpn"
    exit 1
fi
if [[ ! -f "${STATUS_LOG_PATH}" ]]; then
    echo "Log of openvpn doesn't exist"
fi

if [[ "${STATS_MONITOR_PATH}" == "" ]]; then
    echo "Specify path to file with monitoring stats"
    exit 1
fi

if [[ "${TIMEOUT}" == "" ]]; then
    TIMEOUT=60
fi

if [[ "${LOG_PATH}" == "" ]]; then
    LOG_PATH="$STATS_MONITOR_PATH.ovpn_monitor.debug_log"
fi

echo "OpenVPN Monitor started at:" `date` >> "$LOG_PATH"

BACKUP_STATS_MONITOR_PATH="${STATS_MONITOR_PATH}.ovpn_monitor.backup"
TMP_STATS_MONITOR_PATH="${STATS_MONITOR_PATH}.ovpn_monitor.tmp"

declare -A CONNECTIONS

# Format. Each line is one of next:
# 1) OpenVPN@<open_vpn_version>
# 2) StatsDate@<datetime>(<time>)
# 3) <name>_<address>:<port>@<total_received_bytes>,<total_sent_bytes>,<last_connected_since_time>,<received_since_connect_bytes>,<sent_since_connect_bytes>
read_stats()
{
    local FILE=$1

    if [[ ! -f "${FILE}" ]]; then
        return
    fi

    while IFS= read -r LINE; do
        KEY=$(echo $LINE | awk -F '@' '{print $1}')
        DATA=$(echo $LINE | awk -F '@' '{print $2}')

        if [[ "$KEY" != "OpenVPN" && "$KEY" != "StatsDate" ]]; then
            CONNECTIONS["${KEY}"]="$DATA"
        fi
    done < "$FILE"
}

# Format of stats file:
# 1) Each line in monitoring stats corresponds to one client with network usage stats, and previous connected time range
# 2) Client means combination of unique name and unique real address
#    (since same client can connect from different places and devices)
# 3) Additional info about openvpn version is added
write_stats()
{
    local FILE=$1
    local OPENVPN_VERSION=$2
    local DATETIME=$3
    local TIME=$4

    echo "OpenVPN@${OPENVPN_VERSION}" >> ${FILE}
    echo "StatsDate@${DATETIME}(${TIME})" >> ${FILE}

    for ID in "${!CONNECTIONS[@]}"; do
        DATA="${CONNECTIONS[${ID}]}"
        echo "${ID}@${DATA}" >> ${FILE}
    done
}

parse_log()
{
    while IFS= read -r LINE; do
        TAG=$(echo $LINE | awk -F ',' '{print $1}')

        if [[ "$TAG" == "TITLE" ]]; then
            OPENVPN_VERSION=$(echo $LINE | awk -F ',' '{print $2}')
        elif [[ "$TAG" == "TIME" ]]; then
            DATETIME=$(echo $LINE | awk -F ',' '{print $2}')
            TIME=$(echo $LINE | awk -F ',' '{print $3}')
        elif [[ "$TAG" == "CLIENT_LIST" ]]; then
            NAME=$(echo $LINE | awk -F ',' '{print $2}')
            ADDRESS=$(echo $LINE | awk -F ',' '{print $3}')
            # ID is <name>_<real_address_with_port>
            ID=$(echo $NAME $ADDRESS | awk '{printf("%s_%s", $1, $2);}')
            BYTES_RECEIVED=$(echo $LINE | awk -F ',' '{print $6}')
            BYTES_SENT=$(echo $LINE | awk -F ',' '{print $7}')
            CONNECTED_SINCE_TIME=$(echo $LINE | awk -F ',' '{print $9}')

            NEW_CONNECTIONS["${ID}"]="$BYTES_RECEIVED,$BYTES_SENT,$CONNECTED_SINCE_TIME"
        fi
    done < "$STATUS_LOG_PATH"
}

update_stats()
{
    unset NEW_CONNECTIONS
    unset OPENVPN_VERSION
    unset DATETIME
    unset TIME

    declare -A NEW_CONNECTIONS

    parse_log

    for ID in "${!NEW_CONNECTIONS[@]}"; do
        VALUE="${CONNECTIONS[${ID}]}"
        NEW_VALUE="${NEW_CONNECTIONS[${ID}]}"
        NEW_BYTES_RECEIVED=$(echo $NEW_VALUE | awk -F ',' '{print $1}')
        NEW_BYTES_SENT=$(echo $NEW_VALUE | awk -F ',' '{print $2}')
        NEW_CONNECTED_SINCE_TIME=$(echo $NEW_VALUE | awk -F ',' '{print $3}')

        if [[ "${VALUE}" != "" ]]; then
            TOTAL_BYTES_RECEIVED=$(echo $VALUE | awk -F ',' '{print $1}')
            TOTAL_BYTES_SENT=$(echo $VALUE | awk -F ',' '{print $2}')
            LAST_CONNECTED_SINCE_TIME=$(echo $VALUE | awk -F ',' '{print $3}')

            if [[ "${LAST_CONNECTED_SINCE_TIME}" == "${NEW_CONNECTED_SINCE_TIME}" ]]; then
                # Same connection
                BYTES_RECEIVED_SINCE_CONNECT=$(echo $VALUE | awk -F ',' '{print $4}')
                BYTES_SENT_SINCE_CONNECT=$(echo $VALUE | awk -F ',' '{print $5}')
                TOTAL_BYTES_RECEIVED=$(echo $TOTAL_BYTES_RECEIVED $NEW_BYTES_RECEIVED $BYTES_RECEIVED_SINCE_CONNECT | awk '{print $1+$2-$3}')
                TOTAL_BYTES_SENT=$(echo $TOTAL_BYTES_SENT $NEW_BYTES_SENT $BYTES_SENT_SINCE_CONNECT | awk '{print $1+$2-$3}')
            else
                # New connection
                TOTAL_BYTES_RECEIVED=$(echo $TOTAL_BYTES_RECEIVED $NEW_BYTES_RECEIVED | awk '{print $1+$2}')
                TOTAL_BYTES_SENT=$(echo $TOTAL_BYTES_SENT $NEW_BYTES_SENT | awk '{print $1+$2}')
            fi
        else
            TOTAL_BYTES_RECEIVED="$NEW_BYTES_RECEIVED"
            TOTAL_BYTES_SENT="$NEW_BYTES_SENT"
        fi

        CONNECTIONS["${ID}"]="$TOTAL_BYTES_RECEIVED,$TOTAL_BYTES_SENT,$NEW_CONNECTED_SINCE_TIME,$NEW_BYTES_RECEIVED,$NEW_BYTES_SENT"
    done

    if [[ -f "${STATS_MONITOR_PATH}" ]]; then
        # Copy current version of stats to backup
        cp ${STATS_MONITOR_PATH} ${BACKUP_STATS_MONITOR_PATH}
    fi

    # Create temporary file for new version
    touch ${TMP_STATS_MONITOR_PATH}

    write_stats ${TMP_STATS_MONITOR_PATH} "${OPENVPN_VERSION}" "${DATETIME}" "${TIME}"

    mv ${TMP_STATS_MONITOR_PATH} ${STATS_MONITOR_PATH}
}

# 1. Read existing stats once before starting log analysis
read_stats

while true; do
    # 2. Update stats
    update_stats

    sleep $TIMEOUT
done