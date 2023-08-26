#!/usr/bin/env bash
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e -u
shopt -s extglob

# Set application name from the script's file name
app_name="${0##*/}"
# Show a WARNING message
# $1: message string

_msg_warning() {
    local _msg="${1}"
    printf '[%s] WARNING: %s\n' "${app_name}" "${_msg}" >&2
}

# Show an ERROR message then exit with status
# $1: message string
# $2: exit code number (with 0 does not exit)
_msg_error() {
    local _msg="${1}"
    local _error=${2}
    printf '[%s] ERROR: %s\n' "${app_name}" "${_msg}" >&2
    if (( _error > 0 )); then
        exit "${_error}"
    fi
}

# Sets object string attributes
# $1: object
# $2: an object string attribute
# $3: a value
_set() {
    local _obj="${1}" \
          _var="${2}" \
          _value="${3}" \
          _type
    printf -v "${_obj}_${_var}" \
              "${_value}"
}

# Returns an attribute value for a 
# given object
# $1: an object
# $2: an object attribute
_get() {
    local _obj="${1}" \
          _var="${2}" \
          _msg \
          _ref \
          _type
    _ref="${_obj}_${_var}[@]"
    _type="$(declare -p "${_ref}")"
    [[ "${_type}" == *"declare: "*": not found" ]] && \
      _msg=(
        "Attribute '${_var}' is not defined"
        "for object '${_obj}'") && \
      _msg_error "${_msg[*]}" 1
    [[ "${_type}" == "declare -A "* ]] && \
      echo "${_image[${_var}]}" && \
      return
    printf "%s\n" "${!_ref}"
}

_global_variables() {
    pkg_list=""
    pacman_conf=""
    repo_name=""
    repo_publisher=""
    install_dir=""
    work_dir=""
    gpg_key=""
    gpg_sender=""
    gpg_home=""
    quiet=""
}

# Get correct GRUB module list for a given platform
# Module list from 
# https://bugs.archlinux.org/task/71382#comment202911
# $1: 'bios' or 'efi'
_get_grub_modules(){
    local _mode="${1}"
    _modules=(
      afsplitter boot bufio chain configfile
      disk echo ext2
      gcry_sha256 halt iso9660 linux
      loadenv loopback minicmd  normal 
      part_apple part_gpt part_msdos
      reboot search search_fs_uuid test usb)
    # Encryption specific modules
    _modules+=(
      cryptodisk gcry_rijndael gcry_sha512
      luks2 password_pbkdf2)
    if [[ "${_mode}" != "pc" ]] && \
       [[ "${_mode}" != "pc-eltorito" ]]; then
        _modules+=(
          at_keyboard all_video btrfs cat echo
          diskfilter echo efifwsetup f2fs fat
          font gcry_crc gfxmenu gfxterm gzio
          hfsplus jpeg keylayouts ls lsefi
          lsefimmap lzopio ntfs png read regexp
          search_fs_file search_label serial sleep
          tpm trig usbserial_common usbserial_ftdi
          usbserial_pl2303 usbserial_usbdebug video
          xfs zstd)
    elif [[ "${_mode}" == "pc" ]] || \
         [[ "${_mode}" == "pc-eltorito" ]]; then
        _modules+=(biosdisk)
    fi
    echo "${_modules[*]}"
}

_set_override() {
    local _obj="${1}" \
          _var="${2}" \
          _default="${3}"
    if [[ -v "override_${_obj}_${_var}" ]]; then
        _set "${_obj}" \
             "${_var}" \
             "$(_get "override_${obj}" \
                     "${_var}")"
    elif [[ -z "$(_get "${_obj}" \
                       "${_var}")" ]]; then
        _set "${_obj}" \
             "${_var}" \
             "${_value}"
    fi
}

_override_path() {
    local _obj="${1}" \
          _var="${2}" \
          _value="${3}"
    _set_override "${_obj}" \
                  "${_var}" \
                  "${_value}"
    _set "${_obj}" \
         "${_var}" \
         "$(realpath -- "$(_get "${_obj}" \
                                "${_var}")")"
}

_set_overrides() {
    local _embed
    [[ -v override_embed_cfg ]] &&
        _embed="-embed" 
    _override_path "grub" \
                   "cfg" \
         	  "/usr/lib/arch-grub/grub${_embed}.cfg"
    _override_path "pacman" \
                   "conf" \
         	  "/etc/pacman.conf"
    _set_override "repo" \
                  "name" \
                  "${app_name}"
    _set_override "repo" \
                  "publisher" \
         	 "${repo_name}"
    if [[ -v override_quiet ]]; then
      quiet="${override_quiet}"
    elif [[ -z "${quiet}" ]]; then
      quiet="y"
    fi
    [[ ! -v override_gpg_key ]] || \
      gpg_key="${override_gpg_key}"
    [[ ! -v override_gpg_sender ]] || \
      gpg_sender="${override_gpg_sender}"
    [[ ! -v override_gpg_home ]] || \
      gpg_home="${override_gpg_home}"
}

# Show help usage, with an exit status.
# $1: exit status number.
_usage() {
    IFS='' \
      read -r \
           -d '' \
           usage_text << \
             ENDUSAGETEXT || true
usage: $(_get "app" "name")} [options] <out_file>
  options:
     -C <grub_cfg>        Whether to use a specific configuration
                          file to embed in GRUB.
		          Default: '$(_get "grub" "cfg")}'
     -e                   Whether to load a plain text
                          GRUB configuration from the GRUB
                          binary directory at runtime.
     -L <application>     Sets an alternative entry name
		          Default: '${"application}'
     -a <arch>            Architecture
		          Default: '${arch}'
     -p <boot_method>     Boot method.
		          Default: '${arch}'
     -b [boot_uuids ..]   Boot disks UUIDS, sorted by
                          the repository.
     -K [kernels ..]      Paths of the kernels inside the boot disks.
     -I [initrds ..]      Paths of the initrds inside the boot disks.
     -k [kernel_sums ..]  SHA256 sums of the kernels.
     -i [initrd_sums ..]  SHA256 sum of the initrd.
     -h                   This message
     -o <out_file>        Output GRUB binary.
		          Default: '$(_get "out" "dir")'
     -v                   Enable verbose output
     -w <work_dir>        Set the working directory (can't be a bind mount).
		          Default: '$(_get "work" "dir")}'

  <out_file>    Output GRUB binary.
                Default: BOOT<arch_code>.<platform>.
ENDUSAGETEXT
    printf '%s' "$(_get "usage" "text")"
    exit "${1}"
}

while getopts 'C:L:a:p:b:K:I:k:i:vh?' arg; do
    case "${arg}" in
        C) override_grub_cfg="${OPTARG}" ;;
	e) override_embed_cfg="y" ;;
        L) override_application="${OPTARG}" ;;
        p) override_platform="${OPTARG}" ;;
	b) read -r -a override_boot_uuids <<< "${OPTARG}" ;;
	K) read -r -a override_kernels <<< "${OPTARG}" ;;
	I) read -r -a override_initrds <<< "${OPTARG}" ;;
	k) read -r -a override_kernel_sums <<< "${OPTARG}" ;;
	i) read -r -a override_initrd_sums <<< "${OPTARG}" ;;
        v) override_quiet="n" ;;
        h|?) _usage 0 ;;
        *)
            _msg_error "Invalid argument '${arg}'" 0
            _usage 1
            ;;
    esac
done

shift $((OPTIND - 1))

_set_overrides
_install_pkg ""
