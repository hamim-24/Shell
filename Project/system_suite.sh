#!/usr/bin/env bash
# System Maintenance & Optimization Suite
# Description: Terminal-based TUI toolkit for monitoring, cleanup, updates, backups, and diagnostics.

set -euo pipefail
IFS=$'\n\t'

#############################
# Global Configuration
#############################
SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="System Suite"
CONFIG_DIR="${HOME}/.config/system_suite"
DATA_DIR="${HOME}/.local/share/system_suite"
LOG_FILE="${DATA_DIR}/system_suite.log"
BACKUP_DIR="${DATA_DIR}/backups"
CACHE_DIR="${DATA_DIR}/cache"
ALERT_THRESHOLD_DISK=85
ALERT_THRESHOLD_CPU=90
ALERT_THRESHOLD_TEMP=80
ALERT_THRESHOLD_BATTERY=20
MENU_REFRESH_SECONDS=2
MENU_WIDTH=80
DEFAULT_DISK_TARGET="${HOME:-/}"
DISK_USAGE_PATH="${SYSTEM_SUITE_DISK_PATH:-${DEFAULT_DISK_TARGET}}"
if [[ ! -d "${DISK_USAGE_PATH}" ]]; then
  DISK_USAGE_PATH="/"
fi

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${CACHE_DIR}" "${BACKUP_DIR}"
if ! touch "${LOG_FILE}" 2>/dev/null; then
  printf "Primary log path %s unavailable. Falling back to local workspace.\n" "${LOG_FILE}"
  DATA_DIR="${PWD}/.system_suite_data"
  CONFIG_DIR="${PWD}/.system_suite_config"
  BACKUP_DIR="${DATA_DIR}/backups"
  CACHE_DIR="${DATA_DIR}/cache"
  LOG_FILE="${DATA_DIR}/system_suite.log"
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${CACHE_DIR}" "${BACKUP_DIR}"
  touch "${LOG_FILE}" || {
    printf "Unable to initialize log file. Check permissions.\n"
    exit 1
  }
fi

#############################
# Styling Helpers
#############################
if command -v tput >/dev/null 2>&1; then
  T_COLORS=$(tput colors 2>/dev/null || echo 0)
else
  T_COLORS=0
fi

if [[ ${T_COLORS} -ge 8 ]]; then
  COLOR_RESET="$(tput sgr0)"
  COLOR_TITLE="$(tput setaf 6)"
  COLOR_MUTED="$(tput setaf 7)"
  COLOR_HILIGHT="$(tput bold)$(tput setaf 3)"
  COLOR_SUCCESS="$(tput bold)$(tput setaf 2)"
  COLOR_WARN="$(tput bold)$(tput setaf 1)"
  COLOR_INFO="$(tput setaf 4)"
else
  COLOR_RESET=""
  COLOR_TITLE=""
  COLOR_MUTED=""
  COLOR_HILIGHT=""
  COLOR_SUCCESS=""
  COLOR_WARN=""
  COLOR_INFO=""
fi

spinner() {
  local pid=${1:-}
  [[ -z ${pid} || ! ${pid} =~ ^[0-9]+$ ]] && return 1
  local delay=0.1
  local chars=('|' '/' '-' '\')
  while kill -0 "${pid}" 2>/dev/null; do
    for char in "${chars[@]}"; do
      printf "\r${COLOR_MUTED}%s${COLOR_RESET}" "${char}"
      sleep "${delay}" 2>/dev/null || sleep 1
      kill -0 "${pid}" 2>/dev/null || break 2
    done
  done
  printf "\r"
}

log_msg() {
  local level=${1:-INFO}
  local message=${2:-"No message"}
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)" "${level}" "${message}" | tee -a "${LOG_FILE}" >/dev/null 2>&1 || true
}

trap 'log_msg ERROR "Unexpected exit on line ${LINENO}"' ERR

#############################
# Utility Functions
#############################
require_cmd() {
  local cmd=${1:-}
  [[ -z ${cmd} ]] && { notify_warn "No command specified"; return 1; }
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    notify_warn "Missing dependency: ${cmd}"
    return 1
  fi
}

human_size() {
  local bytes=${1:-0}
  # Handle negative numbers and non-numeric input
  if ! [[ ${bytes} =~ ^[0-9]+$ ]] || [[ ${bytes} -lt 0 ]]; then
    printf "N/A"
    return
  fi
  local units=(B KB MB GB TB)
  local i=0
  while (( bytes > 1024 && i < ${#units[@]} - 1 )); do
    bytes=$(( bytes / 1024 ))
    ((i++))
  done
  printf '%s %s' "${bytes}" "${units[$i]}"
}

confirm() {
  local prompt=${1:-"Continue?"}
  local response
  read -r -p "${prompt} [y/N]: " response || return 1
  local lower_response
  lower_response=$(echo "${response:-n}" | tr '[:upper:]' '[:lower:]')
  [[ ${lower_response} == "y" || ${lower_response} == "yes" ]]
}

pause() {
  read -r -p "Press Enter to continue..." _ || true
}

notify_warn() {
  local message=${1:-"Warning"}
  printf "${COLOR_WARN}%s${COLOR_RESET}\n" "${message}"
  log_msg WARN "${message}"
}

notify_info() {
  local message=${1:-"Info"}
  printf "${COLOR_INFO}%s${COLOR_RESET}\n" "${message}"
  log_msg INFO "${message}"
}

run_or_warn() {
  local description=${1:-"Command"}
  [[ $# -lt 2 ]] && { notify_warn "No command provided to run_or_warn"; return 1; }
  shift
  local output
  local exit_code
  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e
  if [[ ${exit_code} -eq 0 ]]; then
    log_msg INFO "${description} succeeded"
    return 0
  else
    if echo "${output}" | grep -qi "permission\|denied\|fix your permissions" 2>/dev/null; then
      notify_warn "${description} failed: Permission denied"
      local path_hint
      path_hint=$(echo "${output}" | grep -o '/[^ ]*' | head -1 2>/dev/null || true)
      if [[ -n ${path_hint} ]]; then
        printf "${COLOR_WARN}Try: sudo chown -R \$(whoami) %s\n${COLOR_RESET}" "${path_hint}"
      else
        printf "${COLOR_WARN}Check permissions or try with sudo\n${COLOR_RESET}"
      fi
    else
      notify_warn "${description} failed"
      if [[ -n ${output} ]]; then
        printf "${COLOR_MUTED}%s${COLOR_RESET}\n" "${output}"
      fi
    fi
    log_msg WARN "${description} failed (exit ${exit_code}): ${output}"
    return 1
  fi
}

# Enhanced OS Detection
os_name="$(uname -s)"
case "${os_name}" in
  Darwin) OS="macOS" ;;
  Linux) 
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OS="WSL"
    else
      OS="Linux"
    fi
    ;;
  FreeBSD) OS="FreeBSD" ;;
  OpenBSD) OS="OpenBSD" ;;
  NetBSD) OS="NetBSD" ;;
  CYGWIN*|MINGW*|MSYS*) OS="Windows" ;;
  SunOS) OS="Solaris" ;;
  AIX) OS="AIX" ;;
  *) OS="Unix-like" ;;
esac

# Enhanced Package Manager Detection
if command -v brew >/dev/null 2>&1; then
  PKG_MANAGER="brew"
elif command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
elif command -v pacman >/dev/null 2>&1; then
  PKG_MANAGER="pacman"
elif command -v zypper >/dev/null 2>&1; then
  PKG_MANAGER="zypper"
elif command -v pkg >/dev/null 2>&1; then
  PKG_MANAGER="pkg"
elif command -v portage >/dev/null 2>&1; then
  PKG_MANAGER="portage"
elif command -v xbps-install >/dev/null 2>&1; then
  PKG_MANAGER="xbps"
elif command -v apk >/dev/null 2>&1; then
  PKG_MANAGER="apk"
else
  PKG_MANAGER="unknown"
fi

#############################
# TUI Rendering helpers
#############################
clear_screen() {
  tput reset 2>/dev/null || clear
}

print_centered() {
  local text=${1:-""}
  local width=${MENU_WIDTH}
  local text_len=${#text}
  local padding=$(( (width - text_len) / 2 ))
  [[ ${padding} -lt 0 ]] && padding=0
  printf "${COLOR_TITLE}%*s%s%*s${COLOR_RESET}\n" "${padding}" "" "${text}" "${padding}" ""
}

print_rule() {
  printf "${COLOR_MUTED}%s${COLOR_RESET}\n" "$(printf '%*s' "${MENU_WIDTH}" '' | tr ' ' '─')"
}

print_menu_header() {
  print_rule
  print_centered "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  print_centered "${OS} :: ${PKG_MANAGER}"
  print_rule
}

print_stat_line() {
  local label=${1:-"Unknown"}
  local value=${2:-"N/A"}
  printf "%-24s%s\n" "${COLOR_MUTED}${label}:${COLOR_RESET}" "${value}"
}

#############################
# System Information
#############################
get_cpu_usage() {
  case "${OS}" in
    "macOS")
      top -l 1 -n 0 2>/dev/null | awk -F'[:%, ]+' '/CPU usage/ {usage=$4+$7; printf "%.1f", usage; exit}' \
        || ps -A -o %cpu= | awk '{s+=$1} END {if (NR==0) {print "N/A"} else printf "%.1f", s}'
      ;;
    "FreeBSD"|"OpenBSD"|"NetBSD")
      top -d1 2>/dev/null | awk '/^CPU:/ {gsub(/[%,]/,""); for(i=1;i<=NF;i++) if($i=="idle") printf "%.1f", 100-$(i-1); exit}' \
        || ps -ax -o %cpu= | awk '{s+=$1} END {if (NR==0) {print "N/A"} else printf "%.1f", s}'
      ;;
    "Windows"|"WSL")
      if command -v wmic >/dev/null 2>&1; then
        wmic cpu get loadpercentage /value 2>/dev/null | grep LoadPercentage | cut -d= -f2 | tr -d '\r\n' || printf "N/A"
      else
        ps -eo %cpu= | awk '{s+=$1} END {if (NR==0) {print "N/A"} else printf "%.1f", s}'
      fi
      ;;
    *)
      # Linux and other Unix-like systems
      if [[ -r /proc/stat ]]; then
        local local_total local_idle local_total2 local_idle2 local_diff_total local_diff_idle
        read -r _ user nice system idle iowait irq softirq steal < /proc/stat
        local_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local_idle=${idle}
        sleep 0.5
        read -r _ user nice system idle iowait irq softirq steal < /proc/stat
        local_total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local_idle2=${idle}
        local_diff_total=$((local_total2 - local_total))
        local_diff_idle=$((local_idle2 - local_idle))
        if (( local_diff_total > 0 )); then
          awk -v busy="$((local_diff_total - local_diff_idle))" -v total="${local_diff_total}" 'BEGIN {printf "%.1f", (busy/total)*100}'
        else
          printf "N/A"
        fi
      else
        top -bn1 2>/dev/null | awk -F',' '/^%?Cpu/ {
          for (i=1; i<=NF; i++) if ($i ~ /id/) {gsub(/[^0-9.]/,"",$i); idle=$i}
          if (idle=="") idle=0;
          printf "%.1f", (100-idle);
          exit
        }' || ps -eo %cpu= | awk '{s+=$1} END {if (NR==0) {print "N/A"} else printf "%.1f", s}'
      fi
      ;;
  esac
}

get_mem_usage() {
  case "${OS}" in
    "macOS")
      local page_size free_pages inactive_pages speculative_pages total_pages free_bytes total_bytes used_bytes
      if ! page_size=$(vm_stat 2>/dev/null | awk '/page size of/ {gsub("[^0-9]","",$8); print $8; exit}'); then
        printf "N/A"
        return
      fi
      free_pages=$(vm_stat 2>/dev/null | awk '/ free/ {gsub("[^0-9]","",$3); print $3; exit}')
      inactive_pages=$(vm_stat 2>/dev/null | awk '/ inactive/ {gsub("[^0-9]","",$3); print $3; exit}')
      speculative_pages=$(vm_stat 2>/dev/null | awk '/ speculative/ {gsub("[^0-9]","",$3); print $3; exit}')
      if ! total_bytes=$(sysctl -n hw.memsize 2>/dev/null); then
        printf "N/A"
        return
      fi
      free_bytes=$(( (free_pages + inactive_pages + speculative_pages) * page_size ))
      used_bytes=$(( total_bytes - free_bytes ))
      printf "%s used / %s total" "$(human_size "${used_bytes}")" "$(human_size "${total_bytes}")"
      ;;
    "FreeBSD"|"OpenBSD"|"NetBSD")
      local mem_total mem_free mem_used
      if command -v sysctl >/dev/null 2>&1; then
        mem_total=$(sysctl -n hw.physmem 2>/dev/null || echo 0)
        mem_free=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
        local page_size
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        mem_free=$((mem_free * page_size))
        mem_used=$((mem_total - mem_free))
        printf "%s used / %s total" "$(human_size "${mem_used}")" "$(human_size "${mem_total}")"
      else
        printf "N/A"
      fi
      ;;
    "Windows"|"WSL")
      if command -v wmic >/dev/null 2>&1; then
        local mem_total mem_available
        mem_total=$(wmic computersystem get TotalPhysicalMemory /value 2>/dev/null | grep TotalPhysicalMemory | cut -d= -f2 | tr -d '\r\n')
        mem_available=$(wmic OS get AvailablePhysicalMemory /value 2>/dev/null | grep AvailablePhysicalMemory | cut -d= -f2 | tr -d '\r\n')
        if [[ -n ${mem_total} && -n ${mem_available} ]]; then
          local mem_used=$((mem_total - mem_available))
          printf "%s used / %s total" "$(human_size "${mem_used}")" "$(human_size "${mem_total}")"
        else
          printf "N/A"
        fi
      elif [[ -r /proc/meminfo ]]; then
        local mem_total mem_available mem_used
        mem_total=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2 * 1024}')
        mem_available=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
        mem_used=$(( mem_total - mem_available ))
        printf "%s used / %s total" "$(human_size "${mem_used}")" "$(human_size "${mem_total}")"
      else
        printf "N/A"
      fi
      ;;
    *)
      # Linux and other Unix-like systems
      if [[ -r /proc/meminfo ]]; then
        local mem_total mem_available mem_used
        mem_total=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2 * 1024}')
        mem_available=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2 * 1024}' || grep -m1 MemFree /proc/meminfo | awk '{print $2 * 1024}')
        mem_used=$(( mem_total - mem_available ))
        printf "%s used / %s total" "$(human_size "${mem_used}")" "$(human_size "${mem_total}")"
      else
        printf "N/A"
      fi
      ;;
  esac
}

get_disk_usage() {
  local target="${1:-${DISK_USAGE_PATH}}"
  [[ ! -d ${target} ]] && { printf "N/A (invalid path)"; return; }
  local output
  if ! output=$(df -h "${target}" 2>/dev/null | awk 'NR==2{printf "%s|%s|%s", $3, $2, $5}'); then
    printf "N/A"
    return
  fi
  [[ -z ${output} ]] && { printf "N/A"; return; }
  local used total percent
  IFS='|' read -r used total percent <<< "${output}"
  printf "%s used / %s total (%s) @ %s" "${used:-N/A}" "${total:-N/A}" "${percent:-N/A}" "${target}"
}

get_uptime() {
  case "${OS}" in
    "macOS"|"FreeBSD"|"OpenBSD"|"NetBSD")
      uptime | sed 's/.*, //' 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//'
      ;;
    "Windows")
      if command -v wmic >/dev/null 2>&1; then
        local boot_time current_time uptime_seconds
        boot_time=$(wmic os get lastbootuptime /value 2>/dev/null | grep LastBootUpTime | cut -d= -f2 | cut -c1-14)
        current_time=$(date +%Y%m%d%H%M%S)
        if [[ -n ${boot_time} ]]; then
          uptime_seconds=$(( (current_time - boot_time) * 60 ))
          local days hours minutes
          days=$((uptime_seconds / 86400))
          hours=$(((uptime_seconds % 86400) / 3600))
          minutes=$(((uptime_seconds % 3600) / 60))
          printf "%d days, %d hours, %d minutes" "${days}" "${hours}" "${minutes}"
        else
          printf "N/A"
        fi
      else
        uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//'
      fi
      ;;
    *)
      # Linux, WSL, and other Unix-like systems
      uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//'
      ;;
  esac
}

get_cpu_info() {
  case "${OS}" in
    "macOS")
      sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/  */ /g' || echo "N/A"
      ;;
    "Linux"|"WSL")
      grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo "N/A"
      ;;
    *)
      uname -p 2>/dev/null || echo "N/A"
      ;;
  esac
}

get_cpu_cores() {
  case "${OS}" in
    "macOS")
      sysctl -n hw.ncpu 2>/dev/null || echo "N/A"
      ;;
    "Linux"|"WSL")
      nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "N/A"
      ;;
    *)
      sysctl -n hw.ncpu 2>/dev/null || echo "N/A"
      ;;
  esac
}

get_load_average() {
  if [[ -r /proc/loadavg ]]; then
    awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg 2>/dev/null
  else
    uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo "N/A"
  fi
}

get_network_info() {
  local interface
  case "${OS}" in
    "macOS")
      interface=$(route get default 2>/dev/null | awk '/interface:/ {print $2}' || echo "en0")
      ;;
    *)
      interface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")
      ;;
  esac
  echo "${interface}"
}

get_total_processes() {
  ps aux 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "N/A"
}

get_users_logged() {
  who 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "N/A"
}

system_info_dashboard() {
  clear_screen
  print_menu_header
  
  printf "${COLOR_HILIGHT}System Information:${COLOR_RESET}\n"
  print_stat_line "Hostname" "$(hostname 2>/dev/null || echo 'N/A')"
  print_stat_line "Operating System" "${OS}"
  print_stat_line "Kernel" "$(uname -sr 2>/dev/null || echo 'N/A')"
  print_stat_line "Architecture" "$(uname -m 2>/dev/null || echo 'N/A')"
  print_stat_line "Uptime" "$(get_uptime)"
  
  printf "\n${COLOR_HILIGHT}Hardware Information:${COLOR_RESET}\n"
  print_stat_line "CPU Model" "$(get_cpu_info | cut -c1-50)"
  print_stat_line "CPU Cores" "$(get_cpu_cores)"
  print_stat_line "CPU Usage" "$(get_cpu_usage)%"
  print_stat_line "Load Average" "$(get_load_average)"
  print_stat_line "Memory Usage" "$(get_mem_usage)"
  
  printf "\n${COLOR_HILIGHT}Storage Information:${COLOR_RESET}\n"
  print_stat_line "Root Disk" "$(get_disk_usage /)"
  if [[ ${DISK_USAGE_PATH} != "/" ]]; then
    print_stat_line "Home Disk" "$(get_disk_usage)"
  fi
  
  printf "\n${COLOR_HILIGHT}Network Information:${COLOR_RESET}\n"
  local ip_addr
  if [[ ${OS} == "macOS" ]]; then
    ip_addr=$(ipconfig getifaddr en0 2>/dev/null || ifconfig en0 2>/dev/null | awk '/inet / {print $2}' || echo 'N/A')
  else
    ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo 'N/A')
  fi
  print_stat_line "IP Address" "${ip_addr}"
  print_stat_line "Network Interface" "$(get_network_info)"
  
  printf "\n${COLOR_HILIGHT}System Activity:${COLOR_RESET}\n"
  print_stat_line "Total Processes" "$(get_total_processes)"
  print_stat_line "Users Logged In" "$(get_users_logged)"
  print_stat_line "Package Manager" "${PKG_MANAGER}"
  print_stat_line "Shell" "$(basename "${SHELL}" 2>/dev/null || echo 'N/A')"
  
  printf "\n${COLOR_HILIGHT}System Status:${COLOR_RESET}\n"
  print_stat_line "Current Time" "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
  print_stat_line "Last Boot" "$(uptime -s 2>/dev/null || echo 'N/A')"
  print_stat_line "Last Log Entry" "$(tail -1 "${LOG_FILE}" 2>/dev/null | cut -c1-50 || echo 'None')"
  
  print_rule
  pause
}

#############################
# Disk Cleanup
#############################
get_cleanup_targets() {
  local -a targets
  
  # Common temp/cache directories
  targets+=("/tmp")
  [[ -d "${HOME}/.cache" ]] && targets+=("${HOME}/.cache")
  [[ -d "${HOME}/.local/share/Trash" ]] && targets+=("${HOME}/.local/share/Trash")
  
  # macOS specific
  if [[ ${OS} == "macOS" ]]; then
    [[ -d "${HOME}/Library/Caches" ]] && targets+=("${HOME}/Library/Caches")
    [[ -d "${HOME}/Library/Logs" ]] && targets+=("${HOME}/Library/Logs")
    [[ -d "${HOME}/.Trash" ]] && targets+=("${HOME}/.Trash")
    [[ -d "${HOME}/Library/Application Support/CrashReporter" ]] && targets+=("${HOME}/Library/Application Support/CrashReporter")
    [[ -d "${HOME}/Library/Safari/LocalStorage" ]] && targets+=("${HOME}/Library/Safari/LocalStorage")
  fi
  
  # Browser caches
  [[ -d "${HOME}/.mozilla/firefox" ]] && targets+=("${HOME}/.mozilla/firefox/*/cache2")
  [[ -d "${HOME}/.config/google-chrome/Default/Cache" ]] && targets+=("${HOME}/.config/google-chrome/Default/Cache")
  [[ -d "${HOME}/Library/Caches/Google/Chrome" ]] && targets+=("${HOME}/Library/Caches/Google/Chrome")
  
  # Development caches
  [[ -d "${HOME}/.npm/_cacache" ]] && targets+=("${HOME}/.npm/_cacache")
  [[ -d "${HOME}/.yarn/cache" ]] && targets+=("${HOME}/.yarn/cache")
  [[ -d "${HOME}/.gradle/caches" ]] && targets+=("${HOME}/.gradle/caches")
  [[ -d "${HOME}/.m2/repository" ]] && targets+=("${HOME}/.m2/repository")
  [[ -d "${HOME}/.cargo/registry" ]] && targets+=("${HOME}/.cargo/registry")
  [[ -d "${HOME}/go/pkg/mod" ]] && targets+=("${HOME}/go/pkg/mod")
  
  # Docker (if present)
  [[ -d "/var/lib/docker/tmp" ]] && targets+=("/var/lib/docker/tmp")
  
  # System logs (with permission check)
  [[ -w "/var/log" ]] && targets+=("/var/log")
  
  printf '%s\n' "${targets[@]}"
}

calculate_cleanup_size() {
  local total=0
  local path
  while IFS= read -r path; do
    [[ -z ${path} ]] && continue
    if [[ -e ${path} ]]; then
      local size
      size=$(du -sk "${path}" 2>/dev/null | awk '{print $1}' || echo 0)
      [[ ${size} =~ ^[0-9]+$ ]] && total=$(( total + size ))
    fi
  done
  human_size $(( total * 1024 ))
}

disk_cleanup() {
  clear_screen
  print_menu_header
  
  printf "${COLOR_INFO}Scanning for cleanup targets...${COLOR_RESET}\n"
  local cleanup_targets
  cleanup_targets=$(get_cleanup_targets)
  
  if [[ -z ${cleanup_targets} ]]; then
    printf "${COLOR_WARN}No cleanup targets found.${COLOR_RESET}\n"
    pause
    return
  fi
  
  printf "\n${COLOR_INFO}Cleanup Targets:${COLOR_RESET}\n"
  local idx=1
  while IFS= read -r target; do
    if [[ -e ${target} ]]; then
      local size
      size=$(du -sh "${target}" 2>/dev/null | awk '{print $1}' || echo "N/A")
      printf "[%d] %s (%s)\n" "${idx}" "${target}" "${size}"
      ((idx++))
    fi
  done <<< "${cleanup_targets}"
  
  printf "\n${COLOR_HILIGHT}Total reclaimable space: %s${COLOR_RESET}\n" "$(echo "${cleanup_targets}" | calculate_cleanup_size)"
  
  printf "\n1) Clean all targets\n2) Select specific targets\n0) Cancel\n"
  read -r -p "Choose option: " choice
  
  case "${choice}" in
    1)
      if confirm "Clean all targets?"; then
        local cleaned=0
        while IFS= read -r target; do
          if [[ -e ${target} ]]; then
            if [[ -w ${target} ]] || [[ -w $(dirname "${target}") ]]; then
              if rm -rf "${target}"/* "${target}"/.[^.]* 2>/dev/null; then
                printf "${COLOR_SUCCESS}✓ Cleaned %s${COLOR_RESET}\n" "${target}"
                log_msg INFO "Cleaned ${target}"
                ((cleaned++))
              else
                printf "${COLOR_WARN}✗ Failed to clean %s${COLOR_RESET}\n" "${target}"
              fi
            else
              printf "${COLOR_WARN}✗ No permission for %s${COLOR_RESET}\n" "${target}"
            fi
          fi
        done <<< "${cleanup_targets}"
        printf "\n${COLOR_SUCCESS}Cleanup completed. Cleaned %d locations.${COLOR_RESET}\n" "${cleaned}"
      fi
      ;;
    2)
      printf "\nEnter target numbers (space-separated, e.g., '1 3 5'): "
      read -r -a selected
      if [[ ${#selected[@]} -gt 0 ]]; then
        local -a target_array
        while IFS= read -r target; do
          [[ -e ${target} ]] && target_array+=("${target}")
        done <<< "${cleanup_targets}"
        
        for num in "${selected[@]}"; do
          if [[ ${num} =~ ^[0-9]+$ ]] && [[ ${num} -ge 1 ]] && [[ ${num} -le ${#target_array[@]} ]]; then
            local target="${target_array[$((num-1))]}"
            if rm -rf "${target}"/* "${target}"/.[^.]* 2>/dev/null; then
              printf "${COLOR_SUCCESS}✓ Cleaned %s${COLOR_RESET}\n" "${target}"
              log_msg INFO "Cleaned ${target}"
            else
              printf "${COLOR_WARN}✗ Failed to clean %s${COLOR_RESET}\n" "${target}"
            fi
          fi
        done
      fi
      ;;
    0)
      printf "${COLOR_MUTED}Cleanup cancelled.${COLOR_RESET}\n"
      ;;
  esac
  
  pause
}

#############################
# Package Updates
#############################
get_outdated_count() {
  local count
  case "${PKG_MANAGER}" in
    brew) count=$(brew outdated 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo 0) ;;
    apt) count=$(apt list --upgradable 2>/dev/null | grep -c upgradable 2>/dev/null || echo 0) ;;
    dnf) count=$(dnf check-update -q 2>/dev/null | grep -c '^[^[:space:]]' 2>/dev/null || echo 0) ;;
    yum) count=$(yum check-update -q 2>/dev/null | grep -c '^[^[:space:]]' 2>/dev/null || echo 0) ;;
    pacman) count=$(pacman -Qu 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo 0) ;;
    zypper) count=$(zypper list-updates 2>/dev/null | grep -c '|' 2>/dev/null || echo 0) ;;
    pkg) count=$(pkg version -v 2>/dev/null | grep -c '<' 2>/dev/null || echo 0) ;;
    xbps) count=$(xbps-install -un 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo 0) ;;
    apk) count=$(apk list -u 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo 0) ;;
    *) count=0 ;;
  esac
  [[ ${count} =~ ^[0-9]+$ ]] && echo "${count}" || echo 0
}

run_pkg_update() {
  case "${PKG_MANAGER}" in
    brew) 
      run_or_warn "Brew update" brew update
      run_or_warn "Brew upgrade" brew upgrade
      ;;
    apt) 
      run_or_warn "APT update" sudo apt update
      run_or_warn "APT upgrade" sudo apt upgrade -y
      ;;
    dnf) run_or_warn "DNF upgrade" sudo dnf upgrade -y ;;
    yum) run_or_warn "YUM update" sudo yum update -y ;;
    pacman) run_or_warn "Pacman update" sudo pacman -Syu --noconfirm ;;
    zypper) run_or_warn "Zypper update" sudo zypper update -y ;;
    pkg) run_or_warn "PKG upgrade" sudo pkg upgrade -y ;;
    xbps) run_or_warn "XBPS update" sudo xbps-install -Su ;;
    apk) run_or_warn "APK upgrade" sudo apk upgrade ;;
    *) notify_warn "Unsupported package manager: ${PKG_MANAGER}" ;;
  esac
}

list_outdated() {
  case "${PKG_MANAGER}" in
    brew) run_or_warn "Listing outdated packages" brew outdated ;;
    apt) run_or_warn "Listing upgradable packages" apt list --upgradable ;;
    dnf) run_or_warn "Checking for updates" dnf check-update ;;
    yum) run_or_warn "Checking for updates" yum check-update ;;
    pacman) run_or_warn "Listing outdated packages" pacman -Qu ;;
    zypper) run_or_warn "Listing updates" zypper list-updates ;;
    pkg) run_or_warn "Checking package versions" pkg version -v ;;
    xbps) run_or_warn "Listing updates" xbps-install -un ;;
    apk) run_or_warn "Listing upgradable packages" apk list -u ;;
    *) notify_warn "Unsupported package manager: ${PKG_MANAGER}" ;;
  esac
}

clean_cache() {
  case "${PKG_MANAGER}" in
    brew) 
      run_or_warn "Brew cleanup" brew cleanup
      run_or_warn "Brew autoremove" brew autoremove
      ;;
    apt) 
      run_or_warn "APT autoremove" sudo apt autoremove -y
      run_or_warn "APT autoclean" sudo apt autoclean
      run_or_warn "APT clean" sudo apt clean
      ;;
    dnf) 
      run_or_warn "DNF autoremove" sudo dnf autoremove -y
      run_or_warn "DNF clean" sudo dnf clean all
      ;;
    yum) 
      run_or_warn "YUM autoremove" sudo yum autoremove -y
      run_or_warn "YUM clean" sudo yum clean all
      ;;
    pacman) 
      run_or_warn "Pacman orphan removal" sudo pacman -Rns $(pacman -Qtdq) 2>/dev/null || true
      run_or_warn "Pacman cache clean" sudo pacman -Sc --noconfirm
      ;;
    zypper) 
      run_or_warn "Zypper clean" sudo zypper clean -a
      ;;
    pkg) 
      run_or_warn "PKG autoremove" sudo pkg autoremove -y
      run_or_warn "PKG clean" sudo pkg clean -y
      ;;
    xbps) 
      run_or_warn "XBPS remove orphans" sudo xbps-remove -o
      run_or_warn "XBPS clean cache" sudo xbps-remove -O
      ;;
    apk) 
      run_or_warn "APK cache clean" sudo rm -rf /var/cache/apk/*
      ;;
    *) notify_warn "Unsupported package manager: ${PKG_MANAGER}" ;;
  esac
}

package_updates() {
  clear_screen
  print_menu_header
  
  printf "${COLOR_INFO}Package Manager:${COLOR_RESET} %s\n" "${PKG_MANAGER}"
  
  if [[ ${PKG_MANAGER} != "unknown" ]]; then
    printf "${COLOR_INFO}Checking for updates...${COLOR_RESET}\n"
    local outdated_count
    outdated_count=$(get_outdated_count)
    if [[ ${outdated_count} -gt 0 ]]; then
      printf "${COLOR_WARN}%s packages can be updated${COLOR_RESET}\n\n" "${outdated_count}"
    else
      printf "${COLOR_SUCCESS}All packages are up to date${COLOR_RESET}\n\n"
    fi
  else
    printf "${COLOR_WARN}No supported package manager found${COLOR_RESET}\n\n"
  fi
  
  printf "1) Update all packages\n2) List outdated packages\n3) Clean cache & orphans\n4) Search packages\n5) Install package\n6) Remove package\n7) Show all packages\n0) Back\n"
  read -r -p "Select option: " choice
  
  case "${choice}" in
    1)
      if [[ ${PKG_MANAGER} == "unknown" ]]; then
        notify_warn "No supported package manager found"
      else
        printf "${COLOR_WARN}This will update all packages. Continue?${COLOR_RESET}\n"
        if confirm "Proceed with update"; then
          run_pkg_update
          printf "${COLOR_SUCCESS}Update completed${COLOR_RESET}\n"
        fi
      fi
      ;;
    2)
      list_outdated
      ;;
    3)
      if confirm "Clean package cache and remove orphaned packages"; then
        clean_cache
        printf "${COLOR_SUCCESS}Cleanup completed${COLOR_RESET}\n"
      fi
      ;;
    4)
      read -r -p "Enter search term: " search_term
      if [[ -n ${search_term} ]]; then
        printf "\n${COLOR_INFO}Searching for packages containing '%s'...${COLOR_RESET}\n" "${search_term}"
        case "${PKG_MANAGER}" in
          brew) 
            brew search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          apt) 
            apt search "${search_term}" 2>/dev/null | grep -v "WARNING" | head -20 || notify_warn "No packages found"
            ;;
          dnf) 
            dnf search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          yum) 
            yum search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          pacman) 
            pacman -Ss "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          zypper) 
            zypper search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          pkg) 
            pkg search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          xbps) 
            xbps-query -Rs "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          apk) 
            apk search "${search_term}" 2>/dev/null | head -20 || notify_warn "No packages found"
            ;;
          *) notify_warn "Search not supported for ${PKG_MANAGER}" ;;
        esac
        printf "\n${COLOR_MUTED}Showing first 20 results${COLOR_RESET}\n"
      else
        notify_warn "No search term provided"
      fi
      ;;
    5)
      read -r -p "Enter package name to install: " pkg_name
      if [[ -n ${pkg_name} ]]; then
        printf "\n${COLOR_INFO}Installing package '%s'...${COLOR_RESET}\n" "${pkg_name}"
        local install_success=false
        case "${PKG_MANAGER}" in
          brew) 
            if run_or_warn "Installing ${pkg_name}" brew install "${pkg_name}"; then
              install_success=true
            fi
            ;;
          apt) 
            if run_or_warn "Installing ${pkg_name}" sudo apt install -y "${pkg_name}"; then
              install_success=true
            fi
            ;;
          dnf) 
            if run_or_warn "Installing ${pkg_name}" sudo dnf install -y "${pkg_name}"; then
              install_success=true
            fi
            ;;
          yum) 
            if run_or_warn "Installing ${pkg_name}" sudo yum install -y "${pkg_name}"; then
              install_success=true
            fi
            ;;
          pacman) 
            if run_or_warn "Installing ${pkg_name}" sudo pacman -S --noconfirm "${pkg_name}"; then
              install_success=true
            fi
            ;;
          zypper) 
            if run_or_warn "Installing ${pkg_name}" sudo zypper install -y "${pkg_name}"; then
              install_success=true
            fi
            ;;
          pkg) 
            if run_or_warn "Installing ${pkg_name}" sudo pkg install -y "${pkg_name}"; then
              install_success=true
            fi
            ;;
          xbps) 
            if run_or_warn "Installing ${pkg_name}" sudo xbps-install -S "${pkg_name}"; then
              install_success=true
            fi
            ;;
          apk) 
            if run_or_warn "Installing ${pkg_name}" sudo apk add "${pkg_name}"; then
              install_success=true
            fi
            ;;
          *) notify_warn "Install not supported for ${PKG_MANAGER}" ;;
        esac
        
        if [[ ${install_success} == true ]]; then
          printf "\n${COLOR_SUCCESS}Package '%s' installed successfully${COLOR_RESET}\n" "${pkg_name}"
        else
          printf "\n${COLOR_WARN}Package '%s' installation failed${COLOR_RESET}\n" "${pkg_name}"
        fi
      else
        notify_warn "No package name provided"
      fi
      ;;
    6)
      read -r -p "Enter package name to remove: " pkg_name
      if [[ -n ${pkg_name} ]] && confirm "Remove package ${pkg_name}"; then
        printf "\n${COLOR_INFO}Removing package '%s'...${COLOR_RESET}\n" "${pkg_name}"
        local remove_success=false
        case "${PKG_MANAGER}" in
          brew) 
            if run_or_warn "Removing ${pkg_name}" brew uninstall "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          apt) 
            if run_or_warn "Removing ${pkg_name}" sudo apt remove -y "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          dnf) 
            if run_or_warn "Removing ${pkg_name}" sudo dnf remove -y "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          yum) 
            if run_or_warn "Removing ${pkg_name}" sudo yum remove -y "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          pacman) 
            if run_or_warn "Removing ${pkg_name}" sudo pacman -R --noconfirm "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          zypper) 
            if run_or_warn "Removing ${pkg_name}" sudo zypper remove -y "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          pkg) 
            if run_or_warn "Removing ${pkg_name}" sudo pkg delete -y "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          xbps) 
            if run_or_warn "Removing ${pkg_name}" sudo xbps-remove -R "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          apk) 
            if run_or_warn "Removing ${pkg_name}" sudo apk del "${pkg_name}"; then
              remove_success=true
            fi
            ;;
          *) notify_warn "Remove not supported for ${PKG_MANAGER}" ;;
        esac
        
        if [[ ${remove_success} == true ]]; then
          printf "\n${COLOR_SUCCESS}Package '%s' removed successfully${COLOR_RESET}\n" "${pkg_name}"
        else
          printf "\n${COLOR_WARN}Package '%s' removal failed${COLOR_RESET}\n" "${pkg_name}"
        fi
      elif [[ -z ${pkg_name} ]]; then
        notify_warn "No package name provided"
      fi
      ;;
    7)
      printf "\n${COLOR_INFO}Listing all installed packages...${COLOR_RESET}\n"
      case "${PKG_MANAGER}" in
        brew) 
          printf "${COLOR_HILIGHT}Formulae:${COLOR_RESET}\n"
          brew list --formula 2>/dev/null | head -50 || notify_warn "No formulae found"
          printf "\n${COLOR_HILIGHT}Casks:${COLOR_RESET}\n"
          brew list --cask 2>/dev/null | head -50 || notify_warn "No casks found"
          ;;
        apt) 
          dpkg --get-selections 2>/dev/null | grep -v deinstall | head -50 || notify_warn "No packages found"
          ;;
        dnf) 
          dnf list installed 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        yum) 
          yum list installed 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        pacman) 
          pacman -Q 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        zypper) 
          zypper search --installed-only 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        pkg) 
          pkg info 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        xbps) 
          xbps-query -l 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        apk) 
          apk list --installed 2>/dev/null | head -50 || notify_warn "No packages found"
          ;;
        *) notify_warn "List packages not supported for ${PKG_MANAGER}" ;;
      esac
      printf "\n${COLOR_MUTED}Showing first 50 packages${COLOR_RESET}\n"
      ;;
    0) ;;
    *) printf "Invalid choice.\n" ;;
  esac
  
  pause
}

#############################
# Backup Creator
#############################
backup_sources=("${HOME}/Documents" "${HOME}/Desktop" "${HOME}/Pictures")

create_backup() {
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || date '+%Y%m%d_%H%M%S')
  local backup_file="${BACKUP_DIR}/backup_${timestamp}.tar.gz"
  
  # Validate backup sources exist
  local valid_sources=()
  for source in "${backup_sources[@]}"; do
    [[ -d ${source} ]] && valid_sources+=("${source}")
  done
  
  if [[ ${#valid_sources[@]} -eq 0 ]]; then
    notify_warn "No valid backup sources found"
    return 1
  fi
  
  tar -czf "${backup_file}" "${valid_sources[@]}" 2>/dev/null &
  local tar_pid=$!
  spinner "${tar_pid}"
  if wait "${tar_pid}"; then
    printf "Backup stored at %s\n" "${backup_file}"
    log_msg INFO "Created backup ${backup_file}"
  else
    notify_warn "Backup command failed. Check permissions/paths."
    rm -f "${backup_file}" 2>/dev/null || true
  fi
}

backup_creator() {
  clear_screen
  print_menu_header
  printf "${COLOR_INFO}Backup sources:${COLOR_RESET} %s\n" "${backup_sources[*]}"
  if confirm "Create backup now?"; then
    create_backup
    printf "${COLOR_SUCCESS}Backup complete.${COLOR_RESET}\n"
  else
    printf "${COLOR_MUTED}Skipped.${COLOR_RESET}\n"
  fi
  pause
}

#############################
# Process Monitor & Killer
#############################
process_monitor() {
  clear_screen
  print_menu_header
  
  if command -v htop >/dev/null 2>&1 && htop --version >/dev/null 2>&1; then
    printf "${COLOR_INFO}Launching htop (press 'q' to quit)...${COLOR_RESET}\n"
    sleep 1
    htop
    clear_screen
    print_menu_header
  else
    printf "${COLOR_INFO}htop not found. Using ps command fallback...${COLOR_RESET}\n\n"
    printf "${COLOR_HILIGHT}Top processes by CPU usage:${COLOR_RESET}\n"
    set +e
    case "${OS}" in
      "macOS"|"FreeBSD"|"OpenBSD"|"NetBSD")
        if ! ps -ax -o pid,ppid,%cpu,%mem,comm 2>/dev/null | head -20; then
          ps -ax 2>/dev/null | head -20 || ps aux 2>/dev/null | head -20 || echo "Process listing unavailable"
        fi
        ;;
      *)
        if ! ps -eo pid,ppid,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -20; then
          ps -eo pid,ppid,%cpu,%mem,comm 2>/dev/null | head -20 || ps aux 2>/dev/null | head -20 || echo "Process listing unavailable"
        fi
        ;;
    esac
    
    printf "\n${COLOR_HILIGHT}Top processes by memory usage:${COLOR_RESET}\n"
    case "${OS}" in
      "macOS"|"FreeBSD"|"OpenBSD"|"NetBSD")
        if ! ps -ax -o pid,ppid,%cpu,%mem,comm 2>/dev/null | sort -k4 -nr 2>/dev/null | head -20; then
          ps -ax 2>/dev/null | head -20 || ps aux 2>/dev/null | head -20 || echo "Process listing unavailable"
        fi
        ;;
      *)
        if ! ps -eo pid,ppid,%cpu,%mem,comm --sort=-%mem 2>/dev/null | head -20; then
          ps -eo pid,ppid,%cpu,%mem,comm 2>/dev/null | head -20 || ps aux 2>/dev/null | head -20 || echo "Process listing unavailable"
        fi
        ;;
    esac
    set -e
  fi
  
  printf "\n${COLOR_INFO}Process Killer:${COLOR_RESET}\n"
  printf "Enter PID to kill (or blank to skip): "
  local pid
  read -r pid || return
  if [[ -n ${pid} ]]; then
    if [[ ${pid} =~ ^[0-9]+$ ]]; then
      if confirm "Send SIGTERM to ${pid}?"; then
        if run_or_warn "Terminate process ${pid}" kill "${pid}"; then
          printf "${COLOR_SUCCESS}Process terminated.${COLOR_RESET}\n"
        fi
      fi
    else
      notify_warn "Invalid PID: ${pid}"
    fi
  fi
  pause
}

#############################
# Internet Speed Test
#############################
network_speed_test() {
  clear_screen
  print_menu_header
  
  if ! command -v curl >/dev/null 2>&1; then
    notify_warn "curl not found. Speed test requires curl."
    pause
    return
  fi
  
  printf "${COLOR_INFO}Running Internet Speed Test...${COLOR_RESET}\n\n"
  
  # Test download speed with multiple fallback URLs
  printf "Testing download speed (5MB file)...\n"
  local test_urls=(
    "https://httpbin.org/bytes/5242880"
    "https://github.com/microsoft/vscode/archive/refs/heads/main.zip"
    "https://releases.ubuntu.com/20.04/ubuntu-20.04.6-desktop-amd64.iso.torrent"
  )
  
  local success=false
  for url in "${test_urls[@]}"; do
    local start_time end_time duration speed_mbps
    start_time=$(date +%s)
    
    if curl -s -L --max-time 30 -o /dev/null "${url}" 2>/dev/null; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      
      if [[ ${duration} -gt 0 ]]; then
        # 5MB = 40 Megabits, divide by duration in seconds
        speed_mbps=$(awk "BEGIN {printf \"%.2f\", 40 / ${duration}}")
        printf "${COLOR_SUCCESS}Download Speed: %s Mbps (5MB in %ds)${COLOR_RESET}\n" "${speed_mbps}" "${duration}"
      else
        printf "${COLOR_SUCCESS}Download Speed: Very fast (< 1 second)${COLOR_RESET}\n"
      fi
      success=true
      break
    fi
  done
  
  if [[ ${success} == false ]]; then
    printf "${COLOR_WARN}Download test failed - all test servers unreachable${COLOR_RESET}\n"
  fi
  
  # Test latency
  printf "\nTesting latency...\n"
  if command -v ping >/dev/null 2>&1; then
    local ping_result
    ping_result=$(ping -c 4 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}' 2>/dev/null || echo "N/A")
    if [[ ${ping_result} != "N/A" ]]; then
      printf "${COLOR_SUCCESS}Average Latency: %s ms${COLOR_RESET}\n" "${ping_result}"
    else
      printf "${COLOR_WARN}Latency test failed${COLOR_RESET}\n"
    fi
  else
    printf "${COLOR_WARN}ping command not available${COLOR_RESET}\n"
  fi
  
  # Test connectivity
  printf "\nTesting connectivity...\n"
  local sites=("google.com" "github.com" "httpbin.org")
  for site in "${sites[@]}"; do
    if curl -s --connect-timeout 5 "https://${site}" >/dev/null 2>&1; then
      printf "${COLOR_SUCCESS}✓ %s reachable${COLOR_RESET}\n" "${site}"
    else
      printf "${COLOR_WARN}✗ %s unreachable${COLOR_RESET}\n" "${site}"
    fi
  done
  
  pause
}

#############################
# Service Manager
#############################
list_services() {
  printf "\n${COLOR_INFO}Available services:${COLOR_RESET}\n"
  case "${OS}" in
    "macOS")
      printf "${COLOR_HILIGHT}System services:${COLOR_RESET}\n"
      launchctl list 2>/dev/null | grep -v "^-" | head -10 || printf "No services found\n"
      ;;
    "Linux"|"WSL")
      printf "${COLOR_HILIGHT}Active services:${COLOR_RESET}\n"
      systemctl list-units --type=service --state=active 2>/dev/null | head -10 || printf "No services found\n"
      ;;
    *)
      printf "Service listing not supported on ${OS}\n"
      ;;
  esac
}

service_manager() {
  clear_screen
  print_menu_header
  
  case "${OS}" in
    "macOS")
      printf "${COLOR_INFO}Service Manager (macOS launchctl)${COLOR_RESET}\n"
      if ! command -v launchctl >/dev/null 2>&1; then
        notify_warn "launchctl not available"
        pause
        return
      fi
      ;;
    "Linux"|"WSL")
      printf "${COLOR_INFO}Service Manager (Linux systemctl)${COLOR_RESET}\n"
      if ! command -v systemctl >/dev/null 2>&1; then
        notify_warn "systemctl not available"
        pause
        return
      fi
      ;;
    *)
      notify_warn "Service management not supported on ${OS}"
      pause
      return
      ;;
  esac
  
  printf "\n1) Check service status\n2) Start service\n3) Stop service\n4) Restart service\n5) List services\n0) Back\n"
  read -r -p "Select option: " choice
  
  case "${choice}" in
    1|2|3|4)
      read -r -p "Enter service name: " svc
      if [[ -z ${svc} ]]; then
        notify_warn "No service name provided"
        pause
        return
      fi
      
      printf "\n${COLOR_INFO}Managing service '%s'...${COLOR_RESET}\n" "${svc}"
      local success=false
      
      case "${choice}" in
        1)
          case "${OS}" in
            "macOS")
              if run_or_warn "Checking service status" launchctl list "${svc}"; then
                success=true
              fi
              ;;
            "Linux"|"WSL")
              if run_or_warn "Checking service status" systemctl status "${svc}"; then
                success=true
              fi
              ;;
          esac
          ;;
        2)
          if confirm "Start service ${svc}?"; then
            case "${OS}" in
              "macOS")
                if run_or_warn "Starting service" sudo launchctl load "${svc}"; then
                  success=true
                fi
                ;;
              "Linux"|"WSL")
                if run_or_warn "Starting service" sudo systemctl start "${svc}"; then
                  success=true
                fi
                ;;
            esac
          fi
          ;;
        3)
          if confirm "Stop service ${svc}?"; then
            case "${OS}" in
              "macOS")
                if run_or_warn "Stopping service" sudo launchctl unload "${svc}"; then
                  success=true
                fi
                ;;
              "Linux"|"WSL")
                if run_or_warn "Stopping service" sudo systemctl stop "${svc}"; then
                  success=true
                fi
                ;;
            esac
          fi
          ;;
        4)
          if confirm "Restart service ${svc}?"; then
            case "${OS}" in
              "macOS")
                if run_or_warn "Restarting service" sudo launchctl unload "${svc}" && sudo launchctl load "${svc}"; then
                  success=true
                fi
                ;;
              "Linux"|"WSL")
                if run_or_warn "Restarting service" sudo systemctl restart "${svc}"; then
                  success=true
                fi
                ;;
            esac
          fi
          ;;
      esac
      
      if [[ ${success} == true ]]; then
        printf "\n${COLOR_SUCCESS}Service operation completed successfully${COLOR_RESET}\n"
      else
        printf "\n${COLOR_WARN}Service operation failed${COLOR_RESET}\n"
      fi
      ;;
    5)
      list_services
      ;;
    0)
      return
      ;;
    *)
      printf "Invalid choice.\n"
      ;;
  esac
  
  pause
}

#############################
# Battery Health
#############################
battery_health() {
  clear_screen
  print_menu_header
  if [[ ${OS} == "macOS" ]]; then
    pmset -g batt
  elif command -v upower >/dev/null 2>&1; then
    upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep -E 'state|to empty|percentage|capacity'
  else
    printf "Battery data unavailable.\n"
  fi
  pause
}

#############################
# Log Analyzer
#############################
log_analyzer() {
  clear_screen
  print_menu_header
  local log_path
  printf "Log file path [Tab for completion]: "
  read -e -r log_path || return
  [[ -z ${log_path} ]] && { notify_warn "No file path provided"; pause; return; }
  if [[ ! -f ${log_path} ]]; then
    notify_warn "File does not exist: ${log_path}"
    pause
    return
  fi
  if [[ ! -r ${log_path} ]]; then
    notify_warn "File is not readable: ${log_path}"
    pause
    return
  fi
  local keyword
  read -r -p "Keyword filter (optional): " keyword || keyword=""
  local tail_lines
  read -r -p "Tail lines (default 50): " tail_lines || tail_lines="50"
  [[ ! ${tail_lines} =~ ^[0-9]+$ ]] && tail_lines=50
  [[ ${tail_lines} -gt 10000 ]] && tail_lines=10000
  
  if [[ -n ${keyword} ]]; then
    if ! tail -n "${tail_lines}" "${log_path}" 2>/dev/null | grep -i --color=always "${keyword}" 2>/dev/null; then
      notify_info "No matches for '${keyword}' in last ${tail_lines} lines."
    fi
  else
    if ! tail -n "${tail_lines}" "${log_path}" 2>/dev/null; then
      notify_warn "Unable to read ${log_path}"
    fi
  fi
  pause
}

#############################
# Alert Notifications
#############################
send_alert() {
  local message=$1
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "${SCRIPT_NAME}" -message "${message}"
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${SCRIPT_NAME}\""
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "${SCRIPT_NAME}" "${message}"
  else
    printf "Alert: %s\n" "${message}"
  fi
}

check_alerts() {
  local disk_percent
  disk_percent=$(df / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}' 2>/dev/null || echo 0)
  [[ ! ${disk_percent} =~ ^[0-9]+$ ]] && disk_percent=0
  if (( disk_percent >= ALERT_THRESHOLD_DISK )); then
    send_alert "Disk usage high: ${disk_percent}%"
    printf "${COLOR_WARN}Alert: Disk usage is ${disk_percent}%% (threshold: ${ALERT_THRESHOLD_DISK}%%)${COLOR_RESET}\n"
  else
    printf "${COLOR_SUCCESS}No alerts: Disk usage is ${disk_percent}%% (threshold: ${ALERT_THRESHOLD_DISK}%%)${COLOR_RESET}\n"
  fi
}

#############################
# Enhanced File Finder
#############################
open_file() {
  local file=${1:-}
  [[ -z ${file} ]] && { notify_warn "No file specified"; return 1; }
  [[ ! -f ${file} ]] && { notify_warn "File does not exist: ${file}"; return 1; }
  
  printf "\n${COLOR_SUCCESS}Selected:${COLOR_RESET} %s\n" "${file}"
  printf "1) Open with default app\n2) Show file info\n3) Copy path to clipboard\n4) Edit with nvim\n0) Cancel\n"
  local action
  read -r -p "Choose action: " action || return
  
  case "${action}" in
    1)
      if [[ ${OS} == "macOS" ]]; then
        open "${file}" 2>/dev/null && printf "${COLOR_SUCCESS}File opened${COLOR_RESET}\n" || notify_warn "Failed to open file"
      else
        xdg-open "${file}" 2>/dev/null && printf "${COLOR_SUCCESS}File opened${COLOR_RESET}\n" || notify_warn "Failed to open file"
      fi
      ;;
    2)
      printf "\n${COLOR_INFO}File Information:${COLOR_RESET}\n"
      ls -la "${file}" 2>/dev/null || notify_warn "Cannot access file info"
      if command -v file >/dev/null 2>&1; then
        printf "${COLOR_HILIGHT}Type:${COLOR_RESET} %s\n" "$(file "${file}" 2>/dev/null || echo 'Unknown')"
      fi
      ;;
    3)
      if [[ ${OS} == "macOS" ]]; then
        echo "${file}" | pbcopy 2>/dev/null && printf "${COLOR_SUCCESS}Path copied to clipboard${COLOR_RESET}\n" || notify_warn "Failed to copy"
      else
        if command -v xclip >/dev/null 2>&1; then
          echo "${file}" | xclip -selection clipboard 2>/dev/null && printf "${COLOR_SUCCESS}Path copied to clipboard${COLOR_RESET}\n" || notify_warn "Failed to copy"
        else
          printf "${COLOR_INFO}Path: %s${COLOR_RESET}\n" "${file}"
          notify_info "xclip not available - path displayed above"
        fi
      fi
      ;;
    4)
      if command -v nvim >/dev/null 2>&1; then
        nvim "${file}"
      else
        notify_warn "nvim not available"
      fi
      ;;
    0|"")
      return
      ;;
    *)
      notify_warn "Invalid choice: ${action}"
      ;;
  esac
}

fzf_search() {
  local search_dir=$1
  local file_types=$2
  
  printf "${COLOR_INFO}Launching fzf file finder...${COLOR_RESET}\n"
  local fzf_cmd="find \"${search_dir}\" -type f"
  
  if [[ -n ${file_types} ]]; then
    case "${file_types}" in
      "text") fzf_cmd+" \\( -name '*.txt' -o -name '*.md' -o -name '*.log' \\)" ;;
      "code") fzf_cmd+" \\( -name '*.py' -o -name '*.js' -o -name '*.sh' -o -name '*.c' -o -name '*.cpp' -o -name '*.java' \\)" ;;
      "config") fzf_cmd+" \\( -name '*.conf' -o -name '*.cfg' -o -name '*.ini' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \\)" ;;
      "image") fzf_cmd+" \\( -name '*.jpg' -o -name '*.png' -o -name '*.gif' -o -name '*.bmp' -o -name '*.svg' \\)" ;;
    esac
  fi
  
  local selected_file
  if selected_file=$(eval "${fzf_cmd}" 2>/dev/null | fzf --height 60% --border --preview 'head -20 {}' --preview-window=right:50% --header="Press ESC to cancel"); then
    if [[ -n ${selected_file} ]]; then
      open_file "${selected_file}"
    fi
  fi
}

find_fallback() {
  local search_dir=${1:-}
  local pattern=${2:-"*"}
  
  [[ -z ${search_dir} ]] && { notify_warn "No search directory specified"; return 1; }
  [[ ! -d ${search_dir} ]] && { notify_warn "Directory does not exist: ${search_dir}"; return 1; }
  
  printf "\n${COLOR_INFO}Searching for files (max 30 results)...${COLOR_RESET}\n"
  local files
  
  if command -v timeout >/dev/null 2>&1; then
    files=$(timeout 15s find "${search_dir}" -maxdepth 4 -type f -iname "${pattern}" 2>/dev/null | head -30 || true)
  else
    files=$(find "${search_dir}" -maxdepth 4 -type f -iname "${pattern}" 2>/dev/null | head -30 || true)
  fi
  
  if [[ -z ${files} ]]; then
    notify_warn "No files found matching pattern '${pattern}' in ${search_dir}"
    return
  fi
  
  printf "\n${COLOR_INFO}Found files:${COLOR_RESET}\n"
  local -a file_array
  local i=1
  while IFS= read -r file; do
    if [[ -n ${file} && -f ${file} ]]; then
      printf "[%d] %s\n" "${i}" "${file}"
      file_array[${i}]="${file}"
      ((i++))
    fi
  done <<< "${files}"
  
  if [[ ${#file_array[@]} -eq 0 ]]; then
    notify_warn "No valid files found"
    return
  fi
  
  local file_num
  read -r -p "\nSelect file number (or 0 to cancel): " file_num || return
  if [[ ${file_num} =~ ^[0-9]+$ ]] && [[ ${file_num} -ge 1 ]] && [[ ${file_num} -le ${#file_array[@]} ]]; then
    open_file "${file_array[${file_num}]}"
  elif [[ ${file_num} != "0" && -n ${file_num} ]]; then
    notify_warn "Invalid selection: ${file_num}"
  fi
}

file_finder_fzf() {
  clear_screen
  print_menu_header
  
  printf "${COLOR_INFO}File Finder${COLOR_RESET}\n\n"
  printf "1) Search all files (fzf)\n2) Search by file type\n3) Search by pattern\n4) Recent files\n0) Back\n"
  read -r -p "Select search method: " method
  
  case "${method}" in
    1)
      printf "Search directory (default: ${HOME}) [Tab for completion]: "
      read -e -r search_dir
      search_dir=${search_dir:-${HOME}}
      
      if [[ ! -d ${search_dir} ]]; then
        notify_warn "Directory does not exist: ${search_dir}"
        pause
        return
      fi
      
      if command -v fzf >/dev/null 2>&1; then
        fzf_search "${search_dir}" ""
      else
        notify_info "fzf not found. Using find fallback."
        find_fallback "${search_dir}" "*"
      fi
      ;;
    2)
      printf "\nFile types:\n"
      printf "1) Text files (.txt, .md, .log)\n2) Code files (.py, .js, .sh, .c, .cpp, .java)\n3) Config files (.conf, .cfg, .ini, .json, .yaml)\n4) Images (.jpg, .png, .gif, .bmp, .svg)\n"
      read -r -p "Select file type: " type_choice
      
      local file_type
      case "${type_choice}" in
        1) file_type="text" ;;
        2) file_type="code" ;;
        3) file_type="config" ;;
        4) file_type="image" ;;
        *) notify_warn "Invalid choice"; pause; return ;;
      esac
      
      printf "Search directory (default: ${HOME}) [Tab for completion]: "
      read -e -r search_dir
      search_dir=${search_dir:-${HOME}}
      
      if [[ ! -d ${search_dir} ]]; then
        notify_warn "Directory does not exist: ${search_dir}"
        pause
        return
      fi
      
      if command -v fzf >/dev/null 2>&1; then
        fzf_search "${search_dir}" "${file_type}"
      else
        notify_info "fzf not found. Using find fallback."
        case "${file_type}" in
          "text") find_fallback "${search_dir}" "*.txt" ;;
          "code") find_fallback "${search_dir}" "*.py" ;;
          "config") find_fallback "${search_dir}" "*.conf" ;;
          "image") find_fallback "${search_dir}" "*.jpg" ;;
        esac
      fi
      ;;
    3)
      printf "Enter search pattern (e.g., '*.txt', 'config*'): "
      read -e -r pattern
      printf "Search directory (default: ${HOME}) [Tab for completion]: "
      read -e -r search_dir
      search_dir=${search_dir:-${HOME}}
      
      if [[ ! -d ${search_dir} ]]; then
        notify_warn "Directory does not exist: ${search_dir}"
        pause
        return
      fi
      
      if [[ -z ${pattern} ]]; then
        pattern="*"
        printf "${COLOR_INFO}No pattern specified, searching for all files...${COLOR_RESET}\n"
      fi
      
      find_fallback "${search_dir}" "${pattern}"
      ;;
    4)
      printf "\n${COLOR_INFO}Recent files (last 7 days):${COLOR_RESET}\n"
      if command -v fzf >/dev/null 2>&1; then
        local recent_files
        recent_files=$(find "${HOME}" -type f -mtime -7 2>/dev/null | head -100)
        if [[ -n ${recent_files} ]]; then
          local selected_file
          if selected_file=$(echo "${recent_files}" | fzf --height 60% --border --preview 'ls -la {}' --header="Recent files (last 7 days)"); then
            open_file "${selected_file}"
          fi
        else
          notify_warn "No recent files found"
        fi
      else
        find "${HOME}" -type f -mtime -7 2>/dev/null | head -20
        printf "\n${COLOR_MUTED}Install fzf for interactive selection${COLOR_RESET}\n"
      fi
      ;;
    0)
      return
      ;;
    *)
      notify_warn "Invalid choice"
      ;;
  esac
  
  pause
}

#############################
# Time and Date Display
#############################
time_date_display() {
  clear_screen
  print_menu_header
  
  printf "${COLOR_INFO}Current Time and Date:${COLOR_RESET}\n\n"
  
  local current_date current_time timezone uptime_info
  current_date=$(date '+%A, %B %d, %Y')
  current_time=$(date '+%I:%M:%S %p')
  timezone=$(date '+%Z %z')
  uptime_info=$(get_uptime)
  
  printf "${COLOR_HILIGHT}Date:${COLOR_RESET} %s\n" "${current_date}"
  printf "${COLOR_HILIGHT}Time:${COLOR_RESET} %s\n" "${current_time}"
  printf "${COLOR_HILIGHT}Timezone:${COLOR_RESET} %s\n" "${timezone}"
  printf "${COLOR_HILIGHT}Uptime:${COLOR_RESET} %s\n" "${uptime_info}"
  
  if [[ ${OS} == "macOS" ]]; then
    printf "\n${COLOR_INFO}Calendar:${COLOR_RESET}\n"
    cal
  else
    printf "\n${COLOR_INFO}Calendar:${COLOR_RESET}\n"
    cal 2>/dev/null || printf "Calendar not available\n"
  fi
  
  printf "\n${COLOR_INFO}Unix Timestamp:${COLOR_RESET} %s\n" "$(date +%s)"
  printf "${COLOR_INFO}ISO 8601 Format:${COLOR_RESET} %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")"
  
  pause
}

#############################
# File Editor with nvim
#############################
file_editor_nvim() {
  clear_screen
  print_menu_header
  
  if ! command -v nvim >/dev/null 2>&1; then
    notify_warn "nvim (Neovim) not found."
    printf "Install with: brew install neovim (macOS) or your package manager\n"
    pause
    return
  fi
  
  printf "${COLOR_INFO}File Editor (nvim)${COLOR_RESET}\n"
  printf "1) Create new file (Tab for path completion)\n"
  printf "2) Edit existing file (Tab for path completion)\n"
  read -r -p "Select option [1/2]: " editor_choice
  
  local file_path=""
  local create_new=false
  local use_fzf=false
  
  case "${editor_choice}" in
    1)
      create_new=true
      read -e -p "Enter path for new file (Tab for directory completion): " file_path
      ;;
    2)
      create_new=false
      read -e -p "Enter file path to edit (Tab for completion): " file_path
      ;;
  esac
  
  if [[ -z ${file_path} ]]; then
    notify_warn "No file path provided"
    pause
    return
  fi
  
  if [[ ${use_fzf} == true ]]; then
    if [[ ! -f ${file_path} ]]; then
      notify_warn "Selected file does not exist: ${file_path}"
      pause
      return
    fi
    if [[ ! -r ${file_path} ]]; then
      notify_warn "File is not readable: ${file_path}"
      pause
      return
    fi
  else
    local file_dir
    file_dir=$(dirname "${file_path}")
    
    if [[ ! -d ${file_dir} ]]; then
      if [[ ${create_new} == true ]]; then
        if confirm "Directory doesn't exist. Create it?"; then
          if ! mkdir -p "${file_dir}" 2>/dev/null; then
            notify_warn "Failed to create directory: ${file_dir}"
            pause
            return
          fi
        else
          notify_warn "Cannot create file in non-existent directory"
          pause
          return
        fi
      else
        if confirm "Directory doesn't exist. Create it?"; then
          if ! mkdir -p "${file_dir}" 2>/dev/null; then
            notify_warn "Failed to create directory: ${file_dir}"
            pause
            return
          fi
        else
          notify_warn "Cannot edit file in non-existent directory"
          pause
          return
        fi
      fi
    fi
    
    if [[ ${create_new} == true ]] && [[ -f ${file_path} ]]; then
      notify_warn "File already exists: ${file_path}"
      if ! confirm "Edit existing file instead?"; then
        pause
        return
      fi
      create_new=false
    elif [[ ${create_new} == false ]] && [[ ! -f ${file_path} ]]; then
      notify_warn "File does not exist: ${file_path}"
      if ! confirm "Create new file?"; then
        pause
        return
      fi
      create_new=true
    fi
  fi
  
  if [[ -f ${file_path} ]] && [[ ! -w ${file_path} ]]; then
    notify_warn "File exists but is not writable: ${file_path}"
    if ! confirm "Try to edit anyway (may fail)?"; then
      pause
      return
    fi
  fi
  
  if ! command -v nvim >/dev/null 2>&1; then
    notify_warn "nvim not found. Cannot open file."
    pause
    return
  fi
  
  if [[ ${use_fzf} == true ]]; then
    tput reset 2>/dev/null || clear
  else
    clear_screen
  fi
  
  printf "Opening %s with nvim...\n" "${file_path}"
  printf "Press ESC then :q to quit, :wq to save and quit\n\n"
  sleep 0.3
  
  set +e
  nvim "${file_path}"
  local exit_code=$?
  set -e
  
  tput reset 2>/dev/null || clear
  
  if [[ ${exit_code} -ne 0 ]] && [[ ${exit_code} -ne 130 ]]; then
    notify_warn "nvim may have failed. Exit code: ${exit_code}"
  fi
  
  if [[ ${exit_code} -eq 0 ]]; then
    if [[ ${create_new} == true ]]; then
      notify_info "New file created and edited successfully"
      log_msg INFO "Created new file: ${file_path}"
    else
      notify_info "File edited successfully"
      log_msg INFO "Edited file: ${file_path}"
    fi
  elif [[ ${exit_code} -eq 130 ]]; then
    notify_info "nvim cancelled (Ctrl+C or :q without save)"
  else
    notify_warn "nvim exited with code ${exit_code}"
    log_msg WARN "nvim exit code ${exit_code} for file: ${file_path}"
  fi
  
  pause
}

#############################
# Menu Handling
#############################
show_main_menu() {
  clear_screen
  print_menu_header
  printf "${COLOR_HILIGHT}Dashboard:${COLOR_RESET}\n"
  printf "  CPU: %s%%\n" "$(get_cpu_usage 2>/dev/null || echo 'N/A')"
  printf "  Memory: %s\n" "$(get_mem_usage 2>/dev/null || echo 'N/A')"
  printf "  Disk: %s\n" "$(get_disk_usage 2>/dev/null || echo 'N/A')"
  printf "  Uptime: %s\n" "$(get_uptime 2>/dev/null || echo 'N/A')"
  printf "  Time: %s\n" "$(date '+%I:%M:%S %p' 2>/dev/null || date 2>/dev/null || echo 'N/A')"
  print_rule
  cat <<'MENU'
1) System Info Dashboard
2) Disk Cleanup
3) Package Updates
4) Backup Creator
5) Process Monitor & Killer
6) Internet Speed Test
7) Service Manager
8) Battery Health
9) Log Analyzer
10) Alert Check
11) View Logs
12) File Finder (fzf)
13) Time & Date Display
14) File Editor (nvim)
0) Exit
MENU
  print_rule
}

view_logs() {
  clear_screen
  print_menu_header
  if ! tail -n 50 "${LOG_FILE}"; then
    notify_warn "Unable to read ${LOG_FILE}"
  fi
  pause
}

main_loop() {
  while true; do
    show_main_menu
    local choice
    read -r -p "Select option: " choice || { printf "\nExiting...\n"; break; }
    case "${choice}" in
      1) system_info_dashboard ;;
      2) disk_cleanup ;;
      3) package_updates ;;
      4) backup_creator ;;
      5) process_monitor ;;
      6) network_speed_test ;;
      7) service_manager ;;
      8) battery_health ;;
      9) log_analyzer ;;
      10) check_alerts; pause ;;
      11) view_logs ;;
      12) file_finder_fzf ;;
      13) time_date_display ;;
      14) file_editor_nvim ;;
      0|"") printf "Goodbye!\n"; break ;;
      *) printf "Invalid choice: %s\n" "${choice}"; sleep 1 ;;
    esac
  done
}

#############################
# Entry Point
#############################
if [[ ${1:-} == "--non-interactive" ]]; then
  shift
  subcommand=${1:-}
  case "${subcommand}" in
    info) system_info_dashboard ;;
    cleanup) disk_cleanup ;;
    update) package_updates ;;
    backup) backup_creator ;;
    monitor) process_monitor ;;
    speed) network_speed_test ;;
    service) service_manager ;;
    battery) battery_health ;;
    logs) log_analyzer ;;
    find) file_finder_fzf ;;
    time) time_date_display ;;
    edit) file_editor_nvim ;;
    *) printf "Unknown subcommand.\n" ;;
  esac
else
  main_loop
fi
