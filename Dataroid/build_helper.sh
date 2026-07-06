#!/usr/bin/env bash

# Dataroid Build Helper Script
# This script should be added to the host app's Build Phases as a "Run Script"
#
# Usage:
# 1. Add this script to Build Phases -> Run Script
# 2. Add DataroidSDK.xcframework path to "Input Files"
# 3. Optionally add DataroidSnapshotSDK.xcframework as a second Input File
# 4. Set script content to: ./path/to/build_helper.sh
#
# Optional arguments:
# --ignore-fatal-versions          Continue the build on a fatal SDK version response
# --ignore-snapshot-version-check  Continue the build on a DataroidSnapshot version mismatch
#
# The script will:
# - Read DataroidSDK.xcframework path from Input Files ($SCRIPT_INPUT_FILE_0)
# - Optionally read DataroidSnapshotSDK.xcframework from $SCRIPT_INPUT_FILE_1
# - Extract SDK version from framework's Info.plist
# - Fail the build when core and snapshot versions do not match unless --ignore-snapshot-version-check is passed
# - Send version check request to the Dataroid version status service
# - Handle allow/warn/fatal responses appropriately

VERSION_STATUS_URL="https://sdk-version-checker.dataroid.com/version-status"

# Global log file variable
LOG_FILE="/tmp/dataroid_build_helper.log"
MAX_LOG_LINES=100

trim_log_file() {
    if [ -f "${LOG_FILE}" ]; then
        local TEMP_LOG
        TEMP_LOG=$(mktemp /tmp/dataroid_build_helper_log.XXXXXX)
        if tail -n "${MAX_LOG_LINES}" "${LOG_FILE}" > "${TEMP_LOG}"; then
            mv "${TEMP_LOG}" "${LOG_FILE}" || rm -f "${TEMP_LOG}"
        else
            rm -f "${TEMP_LOG}"
        fi
    fi
}

# Override flags, set from script arguments (see parse_arguments)
IGNORE_FATAL_VERSIONS=false
IGNORE_SNAPSHOT_VERSION_CHECK=false

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "${1}" in
            --ignore-fatal-versions)
                IGNORE_FATAL_VERSIONS=true
                ;;
            --ignore-snapshot-version-check)
                IGNORE_SNAPSHOT_VERSION_CHECK=true
                ;;
            *)
                dataroid_log "Ignoring unknown argument: ${1}"
                ;;
        esac
        shift
    done
}

is_ignore_fatal_versions_enabled() {
    [ "${IGNORE_FATAL_VERSIONS}" = "true" ]
}

is_ignore_snapshot_version_check_enabled() {
    [ "${IGNORE_SNAPSHOT_VERSION_CHECK}" = "true" ]
}

dataroid_log() {
    local MESSAGE="${1}"
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    local LOG_LINE="[Dataroid][${TIMESTAMP}]: ${MESSAGE}"
    echo "${LOG_LINE}" >&2
    echo "${LOG_LINE}" >> "${LOG_FILE}"
}

show_popup() {
    local TITLE="${1}"
    local MESSAGE="${2}"
    
    if command -v osascript &> /dev/null && [ -z "${CI}" ]; then
        DATAROID_POPUP_MSG="${MESSAGE}" DATAROID_POPUP_TITLE="${TITLE}" \
            osascript \
                -e 'set messageText to system attribute "DATAROID_POPUP_MSG"' \
                -e 'set titleText to system attribute "DATAROID_POPUP_TITLE"' \
                -e 'display dialog messageText with title titleText buttons {"OK"} default button "OK" with icon caution giving up after 20'
    else
        dataroid_log "Popup skipped because osascript is unavailable or CI is set"
    fi
}

check_sdk_version() {
    local SDK_VERSION="${1}"
    local PLATFORM="ios"
    
    dataroid_log "Checking SDK version compatibility at ${VERSION_STATUS_URL}"
    
    local RESPONSE
    RESPONSE=$(curl -s -S \
        --connect-timeout 5 \
        --max-time 10 \
        -G \
        --data-urlencode "version=${SDK_VERSION}" \
        --data-urlencode "platform=${PLATFORM}" \
        -H "Accept: application/json" \
        "${VERSION_STATUS_URL}" 2>&1)
    
    local CURL_EXIT_CODE=$?
    
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        dataroid_log "Network request failed with exit code ${CURL_EXIT_CODE}. Build will continue."
        return 0
    fi
    
    dataroid_log "Response: ${RESPONSE}"
    
    # Parse JSON response using basic tools. The backend returns build.status,
    # build.showPopup, and build.reason under a nested "build" object.
    local SUCCESS=$(echo "${RESPONSE}" | grep -o '"success"[[:space:]]*:[[:space:]]*[^,}]*' | sed 's/.*:[[:space:]]*//' | tr -d '"')
    
    if [ "${SUCCESS}" != "true" ]; then
        dataroid_log "Backend returned success: false. Build will continue."
        return 0
    fi
    
    local STATUS=$(echo "${RESPONSE}" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//')
    local SHOW_POPUP=$(echo "${RESPONSE}" | grep -o '"showPopup"[[:space:]]*:[[:space:]]*[^,}]*' | sed 's/.*:[[:space:]]*//' | tr -d '"')
    local REASON=$(echo "${RESPONSE}" | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"reason"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//')
    
    dataroid_log "Status: ${STATUS}, ShowPopup: ${SHOW_POPUP}, Reason: ${REASON}"
    
    case "${STATUS}" in
        "allow")
            dataroid_log "SDK version is allowed. Build will continue."
            return 0
            ;;
        "warn")
            dataroid_log "WARNING: ${REASON}"
            if [ "${SHOW_POPUP}" = "true" ]; then
                show_popup "Dataroid SDK Warning" "${REASON}"
            fi
            return 0
            ;;
        "fatal")
            dataroid_log "FATAL: ${REASON}"
            if is_ignore_fatal_versions_enabled; then
                dataroid_log "Build will continue because --ignore-fatal-versions was passed."
                return 0
            fi
            if [ "${SHOW_POPUP}" = "true" ]; then
                show_popup "Dataroid SDK Error" "${REASON}"
            fi
            dataroid_log "Build stopped due to fatal error."
            dataroid_log "To continue at your own risk, pass --ignore-fatal-versions."
            echo "error: [Dataroid] ${REASON}"
            return 1
            ;;
        *)
            dataroid_log "Unknown status: ${STATUS}. Build will continue."
            return 0
            ;;
    esac
}

grep_plist_string() {
    local PLIST_PATH="${1}"
    local KEY="${2}"
    grep -A 1 "${KEY}" "${PLIST_PATH}" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/'
}

find_framework_info_plist() {
    local FRAMEWORK_PATH="${1}"
    local FRAMEWORK_NAME="${2}"

    for arch_dir in "${FRAMEWORK_PATH}"/*/; do
        if [ -d "${arch_dir}" ]; then
            local potential_framework="${arch_dir}${FRAMEWORK_NAME}.framework/Info.plist"
            if [ -f "${potential_framework}" ]; then
                echo "${potential_framework}"
                return 0
            fi
        fi
    done

    return 1
}

extract_version_from_plist() {
    local PLIST_PATH="${1}"
    local VERSION=""

    if command -v /usr/libexec/PlistBuddy &> /dev/null; then
        VERSION=$(/usr/libexec/PlistBuddy -c "Print :DataroidSdkVersion" "${PLIST_PATH}" 2>/dev/null)
        if [ -n "${VERSION}" ]; then
            dataroid_log "PlistBuddy DataroidSdkVersion result: ${VERSION}"
        fi
    fi

    if [ -z "${VERSION}" ] && command -v plutil &> /dev/null; then
        local TEMP_PLIST
        TEMP_PLIST=$(mktemp /tmp/dataroid_temp_info.XXXXXX.plist)
        if plutil -convert xml1 "${PLIST_PATH}" -o "${TEMP_PLIST}" 2>/dev/null; then
            VERSION=$(grep_plist_string "${TEMP_PLIST}" "DataroidSdkVersion")
            if [ -n "${VERSION}" ]; then
                dataroid_log "plutil conversion result: ${VERSION}"
            fi
        fi
        rm -f "${TEMP_PLIST}"
    fi

    if [ -z "${VERSION}" ]; then
        VERSION=$(grep_plist_string "${PLIST_PATH}" "DataroidSdkVersion")
        if [ -n "${VERSION}" ]; then
            dataroid_log "grep/sed result: ${VERSION}"
        fi
    fi

    echo "${VERSION}"
}

extract_version_from_framework() {
    local FRAMEWORK_PATH="${1}"
    local FRAMEWORK_NAME="${2}"
    local FRAMEWORK_DESCRIPTOR="${3:-framework}"
    local VERSION_DESCRIPTOR="${4:-SDK version}"

    local FRAMEWORK_INFO_PLIST
    FRAMEWORK_INFO_PLIST=$(find_framework_info_plist "${FRAMEWORK_PATH}" "${FRAMEWORK_NAME}")
    if [ $? -ne 0 ] || [ -z "${FRAMEWORK_INFO_PLIST}" ]; then
        dataroid_log "Could not find ${FRAMEWORK_NAME}.framework/Info.plist in any architecture folder"
        return 1
    fi

    dataroid_log "Found ${FRAMEWORK_DESCRIPTOR} Info.plist at: ${FRAMEWORK_INFO_PLIST}"

    local VERSION
    VERSION=$(extract_version_from_plist "${FRAMEWORK_INFO_PLIST}")

    if [ -z "${VERSION}" ] || [ "${VERSION}" = "TBD_VERSION" ]; then
        dataroid_log "Could not extract valid ${VERSION_DESCRIPTOR} from ${FRAMEWORK_INFO_PLIST}"
        return 1
    fi

    echo "${VERSION}"
    return 0
}

extract_sdk_version() {
    extract_version_from_framework "${1}" "DataroidSDK" "framework" "SDK version"
}

extract_snapshot_sdk_version() {
    extract_version_from_framework "${1}" "DataroidSnapshotSDK" "snapshot framework" "snapshot SDK version"
}

check_snapshot_version_match() {
    local CORE_VERSION="${1}"
    local SNAPSHOT_FRAMEWORK_PATH="${2}"
    
    if is_ignore_snapshot_version_check_enabled; then
        dataroid_log "Skipping DataroidSnapshot version check because --ignore-snapshot-version-check was passed."
        return 0
    fi
    
    if [[ -z "${SNAPSHOT_FRAMEWORK_PATH}" ]]; then
        return 0
    fi
    
    if [ ! -d "${SNAPSHOT_FRAMEWORK_PATH}" ]; then
        dataroid_log "Snapshot framework path ${SNAPSHOT_FRAMEWORK_PATH} does not exist. Skipping snapshot version check."
        return 0
    fi
    
    local SNAPSHOT_VERSION
    SNAPSHOT_VERSION=$(extract_snapshot_sdk_version "${SNAPSHOT_FRAMEWORK_PATH}")
    local EXTRACT_EXIT_CODE=$?
    
    if [ $EXTRACT_EXIT_CODE -ne 0 ]; then
        dataroid_log "Failed to extract DataroidSnapshot version. Build will continue."
        return 0
    fi
    
    if [ "${CORE_VERSION}" != "${SNAPSHOT_VERSION}" ]; then
        local WARNING_MESSAGE="DataroidSnapshot version (${SNAPSHOT_VERSION}) does not match DataroidCore version (${CORE_VERSION}). Please upgrade DataroidSnapshot SDK to version ${CORE_VERSION}."
        dataroid_log "VERSION MISMATCH: ${WARNING_MESSAGE}"
        echo "error: [Dataroid] ${WARNING_MESSAGE} To skip this check, pass --ignore-snapshot-version-check."
        show_popup "Dataroid SDK Error" "${WARNING_MESSAGE}"
        return 1
    else
        dataroid_log "DataroidSnapshot version matches DataroidCore version (${CORE_VERSION})."
    fi
    
    return 0
}

# Main script execution
main() {
    local FRAMEWORK_PATH="${SCRIPT_INPUT_FILE_0}"
    local SNAPSHOT_FRAMEWORK_PATH="${SCRIPT_INPUT_FILE_1}"
    
    trim_log_file
    dataroid_log "Dataroid Build Helper Script Started..."

    parse_arguments "$@"

    if [[ -z $FRAMEWORK_PATH ]]; then
        dataroid_log "Framework path not found in Input Files! Please add DataroidSDK.xcframework to Input Files in Build Phases."
        exit 0
    fi
    
    if [ ! -d "${FRAMEWORK_PATH}" ]; then
        dataroid_log "Framework path ${FRAMEWORK_PATH} does not exist or is not a directory!"
        exit 0
    fi
    
    # Extract SDK version from framework
    local SDK_VERSION
    SDK_VERSION=$(extract_sdk_version "${FRAMEWORK_PATH}")
    local EXTRACT_EXIT_CODE=$?
    
    if [ $EXTRACT_EXIT_CODE -ne 0 ]; then
        dataroid_log "Failed to extract SDK version. Build will continue."
        exit 0
    fi
    
    dataroid_log "Extracted SDK version: ${SDK_VERSION}"
    
    check_snapshot_version_match "${SDK_VERSION}" "${SNAPSHOT_FRAMEWORK_PATH}"
    local SNAPSHOT_CHECK_EXIT_CODE=$?

    if [ ${SNAPSHOT_CHECK_EXIT_CODE} -ne 0 ]; then
        dataroid_log "Build stopped due to DataroidSnapshot version mismatch."
        exit 1
    fi
    
    # Check SDK version compatibility
    check_sdk_version "${SDK_VERSION}"
    local CHECK_EXIT_CODE=$?
    
    if [ $CHECK_EXIT_CODE -ne 0 ]; then
        dataroid_log "Build stopped due to SDK version check failure."
        exit 1
    fi
    
    dataroid_log "SDK version check completed successfully."
    exit 0
}

# Call main function with all arguments
main "$@"
