#!/usr/bin/env bash

# Copyright 2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may
# not use this file except in compliance with the License. A copy of the
# License is located at
#
#       http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# This script generates a file in go with the license contents as a constant

# Set language to C to make sorting consistent among different environments.

export LANG="C"
export LC_ALL="C"

# Global options
readonly PROGRAM_VERSION="0.0.4"
readonly PROGRAM_SOURCE="https://github.com/awslabs/amazon-eks-ami"
readonly PROGRAM_NAME="$(basename "$0" .sh)"
readonly PROGRAM_DIR="/opt/log-collector"
readonly COLLECT_DIR="/tmp/${PROGRAM_NAME}"
readonly DAYS_7=$(date -d "-7 days" '+%Y-%m-%d %H:%M')
INSTANCE_ID=""
INIT_TYPE=""
PACKAGE_TYPE=""

REQUIRED_UTILS=(
  timeout
  curl
  tar
  date
  mkdir
  iptables
  iptables-save
  grep
  awk
  df
  sysctl
)

COMMON_DIRECTORIES=(
  kernel
  system
  docker
  storage
  var_log
  networking
  ipamd # eks
  sysctls # eks
  kubelet # eks
  cni # eks
)

COMMON_LOGS=(
  syslog
  messages
  aws-routed-eni # eks
  containers # eks
  pods # eks
  cloud-init.log
  cloud-init-output.log
)

# L-IPAMD introspection data points
IPAMD_DATA=(
  enis
  pods
  networkutils-env-settings
  ipamd-env-settings
  eni-configs
)

help() {
  echo "USAGE: ${PROGRAM_NAME} --mode=collect|enable_debug"
  echo "       ${PROGRAM_NAME} --help"
  echo ""
  echo "OPTIONS:"
  echo "     --mode  Sets the desired mode of the script. For more information,"
  echo "             see the MODES section."
  echo "     --help  Show this help message."
  echo ""
  echo "MODES:"
  echo "     collect       Gathers basic operating system, Docker daemon, and Amazon"
  echo "                 EKS related config files and logs. This is the default mode."
  echo "     enable_debug  Enables debug mode for the Docker daemon"
}

parse_options() {
  local count="$#"

  for i in $(seq "${count}"); do
    eval arg="\$$i"
    param="$(echo "${arg}" | awk -F '=' '{print $1}' | sed -e 's|--||')"
    val="$(echo "${arg}" | awk -F '=' '{print $2}')"

    case "${param}" in
      mode)
        eval "${param}"="${val}"
        ;;
      help)
        help && exit 0
        ;;
      *)
        echo "Command not found: '--$param'"
        help && exit 1
        ;;
    esac
  done
}

ok() {
  echo
}

try() {
  local action=$*
  echo -n "Trying to $action... "
}

warning() {
  local reason=$*
  echo -e "\n\n\tWarning: $reason "
}

die() {
  echo -e "\n\tFatal Error! $* Exiting!\n"
  exit 1
}

is_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root!"
  fi
}

check_required_utils() {
  for utils in ${REQUIRED_UTILS[*]}; do
    # if exit code of "command -v" not equal to 0, fail
    if ! command -v "${utils}" >/dev/null 2>&1; then
      die "Application \"${utils}\" is missing, please install \"${utils}\" as this script requires it, and will not function without it."
    fi
  done
}

version_output() {
  echo -e "\n\tThis is version ${PROGRAM_VERSION}. New versions can be found at ${PROGRAM_SOURCE}\n"
}

systemd_check() {
  if  command -v systemctl >/dev/null 2>&1; then
      INIT_TYPE="systemd"
    else
      INIT_TYPE="other"
  fi
}

create_directories() {
  # Make sure the directory the script lives in is there. Not an issue if
  # the EKS AMI is used, as it will have it.
  mkdir --parents "${PROGRAM_DIR}"
  
  # Common directors creation 
  for directory in ${COMMON_DIRECTORIES[*]}; do
    mkdir --parents "${COLLECT_DIR}"/"${directory}"
  done
}

get_instance_metadata() {
  readonly INSTANCE_ID=$(curl --max-time 3 --silent http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  echo "${INSTANCE_ID}" > "${COLLECT_DIR}"/system/instance-id.txt
}

is_diskfull() {
  local threshold
  local result

  # 1.5GB in KB
  threshold=1500000
  result=$(df / | grep --invert-match "Filesystem" | awk '{ print $4 }')

  # If "result" is less than or equal to "threshold", fail.
  if [[ "${result}" -le "${threshold}" ]]; then
    die "Free space on root volume is less than or equal to $((threshold>>10))MB, please ensure adequate disk space to collect and store the log files."
  fi
}

cleanup() {
  rm --recursive --force "${COLLECT_DIR}" >/dev/null 2>&1
}

init() {
  check_required_utils
  version_output
  is_root
  systemd_check
  get_pkgtype
}

collect() {
  init
  is_diskfull
  create_directories
  get_instance_metadata
  get_common_logs
  get_kernel_info
  get_mounts_info
  get_selinux_info
  get_iptables_info
  get_pkglist
  get_system_services
  get_docker_info
  get_eks_logs_and_configfiles
  get_ipamd_info
  get_sysctls_info
  get_networking_info
  get_cni_config
  get_kubelet_info
  get_containers_info
  get_docker_logs
}

enable_debug() {
  init
  enable_docker_debug
}

pack() {
  try "archive gathered information"

  tar --create --verbose --gzip --file "${PROGRAM_DIR}"/eks_"${INSTANCE_ID}"_"$(date --utc +%Y-%m-%d_%H%M-%Z)"_"${PROGRAM_VERSION}".tar.gz --directory="${COLLECT_DIR}" . > /dev/null 2>&1

  ok
}

finished() {
  if [[ "${mode}" == "collect" ]]; then
      cleanup
      echo -e "\n\tDone... your bundled logs are located in ${PROGRAM_DIR}/eks_${INSTANCE_ID}_$(date --utc +%Y-%m-%d_%H%M-%Z)_${PROGRAM_VERSION}.tar.gz\n"
  fi
}

get_mounts_info() {
  try "collect mount points and volume information"
  mount > "${COLLECT_DIR}"/storage/mounts.txt
  echo >> "${COLLECT_DIR}"/storage/mounts.txt
  df --human-readable >> "${COLLECT_DIR}"/storage/mounts.txt
  lsblk > "${COLLECT_DIR}"/storage/lsblk.txt
  lvs > "${COLLECT_DIR}"/storage/lvs.txt
  pvs > "${COLLECT_DIR}"/storage/pvs.txt
  vgs > "${COLLECT_DIR}"/storage/vgs.txt

  ok
}

get_selinux_info() {
  try "collect SELinux status"

  if ! command -v getenforce >/dev/null 2>&1; then
      echo -e "SELinux mode:\n\t Not installed" > "${COLLECT_DIR}"/system/selinux.txt
    else
      echo -e "SELinux mode:\n\t $(getenforce)" > "${COLLECT_DIR}"/system/selinux.txt
  fi

  ok
}

get_iptables_info() {
  try "collect iptables information"

  iptables --numeric --verbose --list --table filter > "${COLLECT_DIR}"/networking/iptables-filter.txt
  iptables --numeric --verbose --list --table nat > "${COLLECT_DIR}"/networking/iptables-nat.txt
  iptables-save > "${COLLECT_DIR}"/networking/iptables-save.out

  ok
}

get_common_logs() {
  try "collect common operating system logs"

  for entry in ${COMMON_LOGS[*]}; do
    if [[ -e "/var/log/${entry}" ]]; then
      cp --force --recursive --dereference /var/log/"${entry}" "${COLLECT_DIR}"/var_log/
    fi
  done

  ok
}

get_kernel_info() {
  try "collect kernel logs"

  if [[ -e "/var/log/dmesg" ]]; then
      cp --force /var/log/dmesg "${COLLECT_DIR}/kernel/dmesg.boot"
  fi
  dmesg > "${COLLECT_DIR}/kernel/dmesg.current"
  dmesg --ctime > "${COLLECT_DIR}/kernel/dmesg.human.current"
  uname -a > "${COLLECT_DIR}/kernel/uname.txt"

  ok
}

get_docker_logs() {
  try "collect Docker daemon logs"

  case "${INIT_TYPE}" in
    systemd)
      journalctl --unit=docker --since "${DAYS_7}" > "${COLLECT_DIR}"/docker/docker.log
      ;;
    other)
      for entry in docker upstart/docker; do
        if [[ -e "/var/log/${entry}" ]]; then
          cp --force --recursive --dereference /var/log/"${entry}" "${COLLECT_DIR}"/docker/
        fi
      done
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_eks_logs_and_configfiles() {
  try "collect kubelet information"

  case "${INIT_TYPE}" in
    systemd)
      timeout 75 journalctl --unit=kubelet --since "${DAYS_7}" > "${COLLECT_DIR}"/kubelet/kubelet.log
      timeout 75 journalctl --unit=kubeproxy --since "${DAYS_7}" > "${COLLECT_DIR}"/kubelet/kubeproxy.log
      timeout 75 kubectl config view --output yaml > "${COLLECT_DIR}"/kubelet/kubeconfig.yaml

      for entry in kubelet kube-proxy; do
        systemctl cat "${entry}" > "${COLLECT_DIR}"/kubelet/"${entry}"_service.txt 2>&1
      done
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_ipamd_info() {
  try "collect L-IPAMD information"

  for entry in ${IPAMD_DATA[*]}; do
      curl --max-time 3 --silent http://localhost:61678/v1/"${entry}" >> "${COLLECT_DIR}"/ipamd/"${entry}".txt
  done

  curl --max-time 3 --silent http://localhost:61678/metrics > "${COLLECT_DIR}"/ipamd/metrics.txt 2>&1

  ok
}

get_sysctls_info() {
  try "collect sysctls information"
  
  sysctl --all >> "${COLLECT_DIR}"/sysctls/sysctl_all.txt

  ok
}

get_networking_info() {
  try "collect networking infomation"

  # ifconfig
  timeout 75 ifconfig > "${COLLECT_DIR}"/networking/ifconfig.txt

  # ip rule show
  timeout 75 ip rule show > "${COLLECT_DIR}"/networking/iprule.txt
  timeout 75 ip route show table all >> "${COLLECT_DIR}"/networking/iproute.txt

  ok
}

get_cni_config() {
  try "collect CNI configuration information"

    if [[ -e "/etc/cni/net.d/" ]]; then
        cp --force --recursive --dereference /etc/cni/net.d/* "${COLLECT_DIR}"/cni/
    fi  

  ok
}

get_pkgtype() {
  if [[ "$(command -v rpm )" ]]; then
    PACKAGE_TYPE=rpm
  elif [[ "$(command -v deb )" ]]; then
    PACKAGE_TYPE=deb
  else
    PACKAGE_TYPE='unknown'
  fi
}

get_pkglist() {
  try "collect installed packages"

  case "${PACKAGE_TYPE}" in
    rpm)
      rpm -qa > "${COLLECT_DIR}"/system/pkglist.txt 2>&1
      ;;
    deb)
      dpkg --list > "${COLLECT_DIR}"/system/pkglist.txt 2>&1
      ;;
    *)
      warning "Unknown package type."
      ;;
  esac

  ok
}

get_system_services() {
  try "collect active system services"

  case "${INIT_TYPE}" in
    systemd)
      systemctl list-units > "${COLLECT_DIR}"/system/services.txt 2>&1
      ;;
    other)
      initctl list | awk '{ print $1 }' | xargs -n1 initctl show-config > "${COLLECT_DIR}"/system/services.txt 2>&1
      printf "\n\n\n\n" >> "${COLLECT_DIR}"/system/services.txt 2>&1
      service --status-all >> "${COLLECT_DIR}"/system/services.txt 2>&1
      ;;
    *)
      warning "Unable to determine active services."
      ;;
  esac

  timeout 75 top -b -n 1 > "${COLLECT_DIR}"/system/top.txt 2>&1
  timeout 75 ps fauxwww > "${COLLECT_DIR}"/system/ps.txt 2>&1
  timeout 75 netstat -plant > "${COLLECT_DIR}"/system/netstat.txt 2>&1

  ok
}

get_docker_info() {
  try "collect Docker daemon information"

  if [[ "$(pgrep dockerd)" -ne 0 ]]; then
    timeout 75 docker info > "${COLLECT_DIR}"/docker/docker-info.txt 2>&1 || echo -e "\tTimed out, ignoring \"docker info output \" "
    timeout 75 docker ps --all --no-trunc > "${COLLECT_DIR}"/docker/docker-ps.txt 2>&1 || echo -e "\tTimed out, ignoring \"docker ps --all --no-truc output \" "
    timeout 75 docker images > "${COLLECT_DIR}"/docker/docker-images.txt 2>&1 || echo -e "\tTimed out, ignoring \"docker images output \" "
    timeout 75 docker version > "${COLLECT_DIR}"/docker/docker-version.txt 2>&1 || echo -e "\tTimed out, ignoring \"docker version output \" "
  else
    warning "The Docker daemon is not running."
  fi

  ok
}

get_containers_info() {
  try "collect running Docker containers and gather container data"

  if [[ "$(pgrep dockerd)" -ne 0 ]]; then
    for i in $(docker ps -q); do
      timeout 75 docker inspect "${i}" > "${COLLECT_DIR}"/docker/container-"${i}".txt 2>&1
    done
  else
    warning "The Docker daemon is not running."
  fi

  ok
}

enable_docker_debug() {
  try "enable debug mode for the Docker daemon"

  case "${PACKAGE_TYPE}" in
    rpm)

      if [[ -e /etc/sysconfig/docker ]] && grep -q "^\s*OPTIONS=\"-D" /etc/sysconfig/docker
      then
        echo "Debug mode is already enabled."
        ok
      else
        if [[ -e /etc/sysconfig/docker ]]; then
          echo "OPTIONS=\"-D \$OPTIONS\"" >> /etc/sysconfig/docker

          try "restart Docker daemon to enable debug mode"
          service docker restart
          ok
        fi
      fi
      ;;
    *)
      warning "The current operating system is not supported."

      ok
      ;;
  esac
}

confirm_enable_docker_debug() {
    read -r -p "${1:-Enabled Docker Debug will restart the Docker Daemon and restart all running container. Are you sure? [y/N]} " USER_INPUT
    case "$USER_INPUT" in
        [yY][eE][sS]|[yY]) 
            enable_docker_debug
            ;;
        *)
            die "\"No\" was selected."
            ;;
    esac
}

parse_options "$@"

if [[ -z "${mode}" ]]; then
 mode="collect"
fi

case "${mode}" in
  collect)
    collect
    pack
    finished
    ;;
  enable_debug)
    confirm_enable_docker_debug
    finished
    ;;
  *)
    help && exit 1
    ;;
esac
