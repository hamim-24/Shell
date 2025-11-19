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
  local pid=$1
  local delay=0.1
  local chars=('|' '/' '-' '\')
  while kill -0 "${pid}" 2>/dev/null; do
    for char in "${chars[@]}"; do
      printf "\r${COLOR_MUTED}%s${COLOR_RESET}" "${char}"
      sleep "${delay}"
      kill -0 "${pid}" 2>/dev/null || break 2
    done
  done
  printf "\r"
}

log_msg() {
  local level=$1
  local message=$2
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}" | tee -a "${LOG_FILE}" >/dev/null
}

trap 'log_msg ERROR "Unexpected exit on line ${LINENO}"' ERR

#############################
# Utility Functions
#############################
require_cmd() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    notify_warn "Missing dependency: ${cmd}"
    return 1
  fi
}

human_size() {
  local bytes=${1:-0}
  if ! [[ ${bytes} =~ ^[0-9]+$ ]]; then
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
  read -r -p "${prompt} [y/N]: " response
  local lower_response
  lower_response=$(echo "${response}" | tr '[:upper:]' '[:lower:]')
  [[ ${lower_response} == "y" || ${lower_response} == "yes" ]]
}

pause() {
  read -r -p "Press Enter to continue..." _ || true
}

notify_warn() {
  local message=$1
  printf "${COLOR_WARN}%s${COLOR_RESET}\n" "${message}"
  log_msg WARN "${message}"
}

notify_info() {
  local message=$1
  printf "${COLOR_INFO}%s${COLOR_RESET}\n" "${message}"
  log_msg INFO "${message}"
}

run_or_warn() {
  local description=$1
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
    if echo "${output}" | grep -qi "permission\|denied\|fix your permissions"; then
      notify_warn "${description} failed: Permission denied"
      local path_hint
      path_hint=$(echo "${output}" | grep -o '/[^ ]*' | head -1 || true)
      if [[ -n ${path_hint} ]]; then
        printf "${COLOR_WARN}Try: sudo chown -R \$(whoami) %s\n${COLOR_RESET}" "${path_hint}"
      else
        printf "${COLOR_WARN}Check Homebrew permissions: brew doctor\n${COLOR_RESET}"
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

os_name="$(uname -s)"
case "${os_name}" in
  Darwin) OS="macOS" ;;
  Linux) OS="Linux" ;;
  *) OS="Unknown" ;;
esac

if command -v brew >/dev/null 2>&1; then
  PKG_MANAGER="brew"
elif command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
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
  local text=$1
  local width=${MENU_WIDTH}
  local padding=$(( (width - ${#text}) / 2 ))
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
  local label=$1
  local value=$2
  printf "%-24s%s\n" "${COLOR_MUTED}${label}:${COLOR_RESET}" "${value}"
}

#############################
# System Information
#############################
get_cpu_usage() {
  if [[ ${OS} == "macOS" ]]; then
    top -l 1 -n 0 2>/dev/null | awk -F'[:%, ]+' '/CPU usage/ {usage=$4+$7; printf "%.1f", usage; exit}' \
      || ps -A -o %cpu= | awk '{s+=$1} END {if (NR==0) {print "N/A"} else printf "%.1f", s}'
  else
    top -bn1 2>/dev/null | awk -F',' '/^%?Cpu/ {
      for (i=1; i<=NF; i++) if ($i ~ /id/) {gsub(/[^0-9.]/,"",$i); idle=$i}
      if (idle=="") idle=0;
      printf "%.1f", (100-idle);
      exit
    }' || {
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
    }
  fi
}

get_mem_usage() {
  if [[ ${OS} == "macOS" ]]; then
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
  else
    local mem_total mem_available mem_used
    mem_total=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2 * 1024}')
    mem_available=$(grep -m1 MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
    mem_used=$(( mem_total - mem_available ))
    printf "%s used / %s total" "$(human_size "${mem_used}")" "$(human_size "${mem_total}")"
  fi
}

get_disk_usage() {
  local target="${1:-${DISK_USAGE_PATH}}"
  if ! output=$(df -h "${target}" 2>/dev/null | awk 'NR==2{printf "%s|%s|%s", $3, $2, $5}'); then
    printf "N/A"
    return
  fi
  IFS='|' read -r used total percent <<< "${output}"
  printf "%s used / %s total (%s) @ %s" "${used}" "${total}" "${percent}" "${target}"
}

get_uptime() {
  if [[ ${OS} == "macOS" ]]; then
    uptime | sed 's/.*, //'
  else
    uptime -p
  fi
}

system_info_dashboard() {
  clear_screen
  print_menu_header
  print_stat_line "Hostname" "$(hostname)"
  print_stat_line "Kernel" "$(uname -sr)"
  print_stat_line "Uptime" "$(get_uptime)"
  print_stat_line "CPU Usage" "$(get_cpu_usage)%"
  print_stat_line "Memory" "$(get_mem_usage)"
  print_stat_line "Disk (${DISK_USAGE_PATH})" "$(get_disk_usage)"
  print_stat_line "IP Address" "$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo 'N/A')"
  print_stat_line "Last Log Entry" "$(tail -1 "${LOG_FILE}" 2>/dev/null || echo 'None')"
  print_rule
  pause
}

#############################
# Disk Cleanup
#############################
cleanup_targets=(
  "/tmp"
  "${HOME}/Library/Caches"
  "${HOME}/.cache"
  "${HOME}/Library/Logs"
  "/var/log"
)

calculate_cleanup_size() {
  local total=0
  for path in "$@"; do
    if [[ -e ${path} ]]; then
      size=$(du -sk "${path}" 2>/dev/null | awk '{print $1}')
      total=$(( total + size ))
    fi
  done
  human_size $(( total * 1024 ))
}

disk_cleanup() {
  clear_screen
  print_menu_header
  printf "${COLOR_INFO}Cleanup Targets:${COLOR_RESET}\n"
  for idx in "${!cleanup_targets[@]}"; do
    printf "[%d] %s\n" "$((idx+1))" "${cleanup_targets[$idx]}"
  done
  printf "\nEstimated reclaimable space: %s\n" "$(calculate_cleanup_size "${cleanup_targets[@]}")"
  if confirm "Proceed with deletion"; then
    for target in "${cleanup_targets[@]}"; do
      if [[ -e ${target} ]]; then
        if rm -rf "${target}"/* 2>/dev/null; then
          log_msg INFO "Cleaned ${target}"
        else
          notify_warn "Failed to clean ${target} (insufficient permissions?)"
        fi
      fi
    done
    printf "${COLOR_SUCCESS}Cleanup completed.${COLOR_RESET}\n"
  else
    printf "${COLOR_MUTED}Cleanup cancelled.${COLOR_RESET}\n"
  fi
  pause
}

#############################
# Package Updates
#############################
run_pkg_update() {
  case "${PKG_MANAGER}" in
    brew) run_or_warn "Brew update/upgrade" bash -c 'brew update && brew upgrade' ;;
    apt) run_or_warn "APT update/upgrade" bash -c 'sudo apt update && sudo apt upgrade -y' ;;
    yum) run_or_warn "YUM update" sudo yum update -y ;;
    dnf) run_or_warn "DNF upgrade" sudo dnf upgrade -y ;;
    *) notify_warn "Unsupported package manager." ;;
  esac
}

package_updates() {
  clear_screen
  print_menu_header
  printf "${COLOR_INFO}Package Manager:${COLOR_RESET} %s\n" "${PKG_MANAGER}"
  printf "1) Update packages\n2) List outdated\n3) Clean cache\n0) Back\n"
  read -r -p "Select option: " choice
  case "${choice}" in
    1)
      run_pkg_update
      ;;
    2)
      case "${PKG_MANAGER}" in
        brew) run_or_warn "Listing brew outdated packages" brew outdated ;;
        apt) run_or_warn "Listing apt upgrades" bash -c 'apt list --upgradable' ;;
        yum|dnf) run_or_warn "Running ${PKG_MANAGER} check-update" sudo "${PKG_MANAGER}" check-update ;;
        *) notify_warn "Unsupported package manager."; ;;
      esac
      ;;
    3)
      case "${PKG_MANAGER}" in
        brew) 
          run_or_warn "Brew cleanup" brew cleanup || true
          ;;
        apt) 
          run_or_warn "APT cleanup" bash -c 'sudo apt autoremove -y && sudo apt clean' || true
          ;;
        yum|dnf) 
          run_or_warn "${PKG_MANAGER} clean" sudo "${PKG_MANAGER}" clean all || true
          ;;
      esac
      ;;
    0) ;;
    *) printf "Invalid.\n" ;;
  esac
  pause
}

#############################
# Backup Creator
#############################
backup_sources=("${HOME}/Documents" "${HOME}/Desktop" "${HOME}/Pictures")

create_backup() {
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local backup_file="${BACKUP_DIR}/backup_${timestamp}.tar.gz"
  tar -czf "${backup_file}" "${backup_sources[@]}" 2>/dev/null &
  local tar_pid=$!
  spinner "${tar_pid}"
  if wait "${tar_pid}"; then
    printf "Backup stored at %s\n" "${backup_file}"
    log_msg INFO "Created backup ${backup_file}"
  else
    notify_warn "Backup command failed. Check permissions/paths."
    rm -f "${backup_file}"
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
  
  if command -v htop >/dev/null 2>&1; then
    printf "${COLOR_INFO}Launching htop (press 'q' to quit)...${COLOR_RESET}\n"
    sleep 1
    htop
    clear_screen
    print_menu_header
  else
    notify_warn "htop not found. Install htop for interactive process monitoring."
  fi
  
  printf "\n${COLOR_INFO}Process Killer:${COLOR_RESET}\n"
  printf "Enter PID to kill (or blank to skip): "
  read -r pid
  if [[ -n ${pid} ]]; then
    if confirm "Send SIGTERM to ${pid}?"; then
      if run_or_warn "Terminate process ${pid}" kill "${pid}"; then
        printf "${COLOR_SUCCESS}Process terminated.${COLOR_RESET}\n"
      fi
    fi
  fi
  pause
}

#############################
# Internet Speed Test
#############################
run_networkquality_test() {
  if [[ ${OS} != "macOS" ]]; then
    return 1
  fi
  if ! command -v networkQuality >/dev/null 2>&1; then
    return 1
  fi
  printf "Running networkQuality summary...\n"
  local output
  if output=$(networkQuality -s 2>&1); then
    printf "%s\n" "${output}"
    return 0
  else
    notify_warn "networkQuality failed: ${output}"
    return 1
  fi
}

network_speed_test() {
  clear_screen
  print_menu_header
  if run_networkquality_test; then
    :
  else
    notify_warn "networkQuality unavailable. Speed test requires macOS with networkQuality command."
  fi
  pause
}

#############################
# Service Manager
#############################
service_manager() {
  clear_screen
  print_menu_header
  printf "Services menu available only on systemd/macOS launchctl.\n"
  read -r -p "Service name: " svc
  printf "1) Status\n2) Start\n3) Stop\n4) Restart\n0) Back\n"
  read -r -p "Choice: " choice
  local cmd
  case "${OS}" in
    macOS) cmd="sudo launchctl" ;;
    Linux) cmd="sudo systemctl" ;;
    *) printf "Not supported."; pause; return ;;
  esac
  case "${choice}" in
    1) run_or_warn "Service status ${svc}" ${cmd} status "${svc}" ;;
    2) run_or_warn "Service start ${svc}" ${cmd} start "${svc}" ;;
    3) run_or_warn "Service stop ${svc}" ${cmd} stop "${svc}" ;;
    4) run_or_warn "Service restart ${svc}" ${cmd} restart "${svc}" ;;
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
  read -r -p "Log file path: " log_path
  if [[ ! -f ${log_path} ]]; then
    printf "${COLOR_WARN}Invalid file.${COLOR_RESET}\n"
    pause
    return
  fi
  read -r -p "Keyword filter (optional): " keyword
  read -r -p "Tail lines (default 50): " tail_lines
  tail_lines=${tail_lines:-50}
  if [[ -n ${keyword} ]]; then
    if ! tail -n "${tail_lines}" "${log_path}" | grep -i --color=always "${keyword}"; then
      notify_info "No matches for '${keyword}' in last ${tail_lines} lines."
    fi
  else
    if ! tail -n "${tail_lines}" "${log_path}"; then
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
  disk_percent=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
  if (( disk_percent >= ALERT_THRESHOLD_DISK )); then
    send_alert "Disk usage high: ${disk_percent}%"
  fi
}

#############################
# File Finder with fzf
#############################
file_finder_fzf() {
  clear_screen
  print_menu_header
  
  if ! command -v fzf >/dev/null 2>&1; then
    notify_warn "fzf not found. Install with: brew install fzf (macOS) or your package manager"
    pause
    return
  fi
  
  local selected_file
  if selected_file=$(find "${HOME}" -type f 2>/dev/null | fzf --height 40% --border --preview 'head -20 {}' --preview-window=right:50%); then
    if [[ -n ${selected_file} ]]; then
      clear_screen
      print_menu_header
      printf "\n${COLOR_SUCCESS}Selected:${COLOR_RESET} %s\n" "${selected_file}"
      read -r -p "Open with default app? [y/N]: " open_choice
      local lower_open
      lower_open=$(echo "${open_choice}" | tr '[:upper:]' '[:lower:]')
      if [[ ${lower_open} == "y" || ${lower_open} == "yes" ]]; then
        if [[ ${OS} == "macOS" ]]; then
          open "${selected_file}" 2>/dev/null || notify_warn "Failed to open file"
        else
          xdg-open "${selected_file}" 2>/dev/null || notify_warn "Failed to open file"
        fi
      fi
    fi
  fi
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
  printf "  CPU: %s%%\n" "$(get_cpu_usage)"
  printf "  Memory: %s\n" "$(get_mem_usage)"
  printf "  Disk: %s\n" "$(get_disk_usage)"
  printf "  Uptime: %s\n" "$(get_uptime)"
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
13) Time & Date
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
    read -r -p "Select option: " choice
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
      0) printf "Goodbye!\n"; break ;;
      *) printf "Invalid choice."; sleep 1 ;;
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
