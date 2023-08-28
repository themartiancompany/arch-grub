#!/usr/bin/env bash
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e -u
shopt -s extglob

# Control the environment
umask 0022
export LC_ALL="C.UTF-8"
# LC_ALL=C.UTF-8, unlike LC_ALL=C, does not override LANGUAGE.
# See https://sourceware.org/bugzilla/show_bug.cgi?id=16621 \
# and https://savannah.gnu.org/bugs/?62815
[[ -v LANGUAGE ]] && \
  unset LANGUAGE
[[ -v SOURCE_DATE_EPOCH ]] || \
  printf -v SOURCE_DATE_EPOCH '%(%s)T' -1
export SOURCE_DATE_EPOCH

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
    _type="$(declare -p "${_obj}_${_var}")"
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
    out_file=""
    grub_cfg=""
    embed_cfg=""
    entry_name=""
    arch_name=""
    boot_method=""
    install_dir=""
    boot_uuids=()
    kernels=()
    initrds=()
    kernel_sums=()
    initrd_sums=()
    work_dir=""
    quiet=""
}

_upper() {
    local _string="${1}"
    echo "${_string}" | \
      tr '[:lower:]' '[:upper:]'
}

_get_platform() {
    local _boot_method="${1}" \
	  _platform
    [[ "${_boot_method}" == "mbr" ]] && \
      _platform="pc"
    [[ "${_boot_method}" == "eltorito" ]] && \
      _platform="pc-eltorito"
    [[ "${_boot_method}" == "efi" ]] && \
      _platform="efi"
    echo "${_platform}"
}

# Get correct GRUB module list for a given platform
# Module list from 
# https://bugs.archlinux.org/task/71382#comment202911
# $1: 'bios' or 'efi'
_get_modules(){
    local _platform="${1}"
    # Base modules
    _modules=(
      afsplitter
      boot
      bufio
      chain
      configfile
      disk
      echo
      ext2
      gcry_sha256
      halt
      iso9660
      linux
      loadenv
      loopback
      minicmd
      normal 
      part_apple
      part_gpt
      part_msdos
      reboot
      regexp
      search
      search_fs_uuid
      test
      usb)
    # Encryption specific modules
    _modules+=(
      cryptodisk
      gcry_rijndael
      gcry_sha512
      luks2
      password_pbkdf2)
    if [[ "${_platform}" != "pc" ]] && \
       [[ "${_platform}" != "pc-eltorito" ]]; then
        _modules+=(
          at_keyboard
	  all_video
	  btrfs
	  cat
          diskfilter
	  efifwsetup
	  f2fs
	  fat
          font
	  gcry_crc
	  gfxmenu
	  gfxterm
	  gzio
          hfsplus
	  jpeg
	  keylayouts
	  ls
	  lsefi
          lsefimmap
	  lzopio
	  ntfs
	  png
	  read 
          search_fs_file
	  search_label
	  serial
	  sleep
          tpm
	  trig
	  usbserial_common
	  usbserial_ftdi
          usbserial_pl2303
	  usbserial_usbdebug
	  video
          xfs
	  zstd
        )
    elif [[ "${_platform}" == "pc" ]] || \
         [[ "${_platform}" == "pc-eltorito" ]]; then
        _modules+=(
	  biosdisk
        )
    fi
    echo "${_modules[*]}"
}

# Fill a bootloader configuration template and copy the result in a file
# $1: bootloader configuration file (templatized, see profile directory)
# $2: bootloader (empty?)
_gen_bootloader_config() {
    local _template="${1}"
    sed "s|%DEVICE_SELECT_CMDLINE%|$(_get_device_select_cmdline)|g;
         s|%ARCH%|${arch_name}|g;
         s|%BOOT_UUIDS%|${boot_uuids[@]}|g;
         s|%INSTALL_DIR%|/${install_dir}|g;
         s|%KERNEL_PARAMS%|$(_get_kernel_params)|g;
         s|%BOOTABLE_UUID%|$(_get_bootable_uuid)|g;
         s|%FALLBACK_UUID%|$(_get_archiso_uuid)|g" \
        "${_template}"
}

_out_name() {
    local _arch="${1}" \
	  _boot_method="${2}" \
          _CODE
    [[ "${_arch}" == "i386" ]] && \
      _CODE="IA32"
    [[ "${_arch}" == "x86_64" ]] && \
      _CODE="x64"
    echo "BOOT$(_CODE).$(_upper "${_boot_method}")"
}

# Produces a standalone GRUB binary
# $1: architecture (x86_64, i386)
# $2: platform (efi, pc)
# $3: output file or directory
#     default name: BOOT<IA32/X64>.EFI
_make_grub() {
    local _boot_method="${1}" \
	  _arch="${2}" \
	  _cfg="${3}" \
	  _out="${4}" \
          _options=() \
          _modules \
	  _platform
    _platform="$(_get_platform \
	             "${_boot_method}")"
    _modules="$(_get_modules \
                    "${_platform}")"
    _options=(
      -O "${_arch}-${_platform}"
      --modules="${_modules}"
      --locales="en@quot"
      --themes=""
      --sbat=/usr/share/grub/sbat.csv
      --disable-shim-lock
      --compress=xz)
    [[ "${_platform}" == "pc"* ]] && \
      _grub_options+=(
        --install-modules="${_modules}"
        --fonts="")
    [ -d "${_out}" ] && \
      _out="${_out}/$(_out_name "${_arch}" \
                                "${_boot_method}")"
    [[ "${_out}" == "" ]] && \
      _out="$(_out_name "${_arch}" \
                        "${_boot_method}")"
    _grub_options+=(
      -o "${_out}")
    grub-mkstandalone "${_options[@]}" \
                      "boot/grub/grub.cfg=${_cfg}"
}

# Build the GRUB binary
_build() {
    [[ "${quiet}" == "y" ]] || \
      _show_config
    _make_grub \
      "$(_get "boot" \
              "method")" \
      "$(_get "arch" \
              "name")" \
      "$(_get "grub" \
              "cfg")" \
      "${out}"
}

# Reassign an object variable if an override
# variable is defined; otherwise it defaults
# to an input default.
# $1: object
# $2: variable
# $3: default value
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

# Re-assign an object variable pointing to
# a path if an override variable is defined,
# otherwise it defaults to an input path
# $1: object
# $2: variable
# $3: value (a path)
_override_path() {
    local _obj="${1}" \
          _var="${2}" \
          _value="${3}" \
          _path
    _path="$(realpath -q -- "${_value}" || \
	     true)"
    [[ "${_path}" == "" ]] && \
      _msg_error "${_value} is not a valid path." 1
    _set_override "${_obj}" \
                  "${_var}" \
                  "${_value}"
    _set "${_obj}" \
         "${_var}" \
         "$(realpath -- "$(_get "${_obj}" \
                                "${_var}")")"
}

# Set defaults and, if present, overrides
# from arch-grub command line option parameters
_set_overrides() {
    local _embed
    [[ -v override_embed_cfg ]] && \
      _embed_cfg="-embed" 
    _override_path "grub" \
                   "cfg" \
         	   "/usr/lib/arch-grub/grub${_embed_cfg}.cfg"
    _set_override "entry" \
                  "name" \
                  "Arch Linux"
    _set_override "arch" \
                  "name" \
         	  "x86_64"
    _set_override "boot" \
                  "method" \
         	  "efi"
    if [[ -v override_quiet ]]; then
      quiet="${override_quiet}"
    elif [[ -z "${quiet}" ]]; then
      quiet="y"
    fi
}

# Show help usage, with an exit status.
# $1: exit status number.
_usage() {
    IFS='' \
      read -r \
           -d '' \
           usage_text << \
             ENDUSAGETEXT || true
usage: $(_get "app" "name") [options] <out_file>
  options:
     -C <grub_cfg>        Whether to use a specific configuration
                          file to embed in GRUB.
		          Default: '$(_get "grub" "cfg")}'
     -e                   Whether to load a plain text
                          GRUB configuration from the GRUB
                          binary directory at runtime.
     -l <entry_name>      Sets an alternative entry name
			  Default: '$(_get "entry""name")'
     -s <short_name>      Short entry name.
     -a <arch_name>       Architecture
			  Default: '$(_get "arch" "name")'
     -p <boot_method>     Boot method (mbr, eltorito, efi).
			  Default: '$(_get "boot" "method")'
     -b [boot_uuids ..]   Boot disks UUIDS, sorted by
                          the repository.
     -K [kernels ..]      Paths of the kernels inside the
                          boot disks.
     -I [initrds ..]      Paths of the initrds inside the
                          boot disks.
     -k [kernel_sums ..]  SHA256 sums of the kernels.
     -i [initrd_sums ..]  SHA256 sums of the initrd.
     -P [keys ..]         Paths of the encryption keys inside
                          the boot disks.
                          Set to "" for unencrypted disks.
                          accordingly.
     -h                   This message.
     -o <out_file>        Output GRUB binary.
		          Default: '$(_get "out" "dir")'
     -v                   Enable verbose output
     -w <work_dir>        Set the working directory (can't be a bind mount).
		          Default: '$(_get "work" "dir")}'

  <out>         Output directory or GRUB binary path.
                Default: ./BOOT<arch_code>.<platform>
ENDUSAGETEXT
    printf '%s\n' "$(_get "usage" "text")"
    exit "${1}"
}

# Shows configuration options.
_show_config() {
    local build_date
    TZ=UTC printf -v build_date '%(%FT%R%z)T' "${SOURCE_DATE_EPOCH}"
    _msg_info "${app_name} configuration settings"
    _msg_info "       Configuration file:   $(_get "grub" "cfg")"
    _msg_info " Plain-text configuration:   ${_embed_cfg:-n}"
    _msg_info "             Architecture:   $(_get "arch" "name")"
    _msg_info "               Entry name:   $(_get "entry" "name")"
    _msg_info "               Short name:   $(_get "short" "name")"
    _msg_info "              Boot Method:   $(_get "boot" "method")"
    _msg_info "               Boot UUIDS:   $(_get "boot" "uuids")"
    _msg_info "                  Kernels:   ${kernels[@]}"
    _msg_info "                  Initrds:   ${initrds[@]}"
    _msg_info "               Build date:   $(_get "build" "date")"
    _msg_info "              Output file:   ${out}"
}

_global_variables

while getopts 'C:e:L:l:a:b:u:K:k:I:i:vh?' arg; do
    case "${arg}" in
        C) override_grub_cfg="${OPTARG}" ;;
	e) override_embed_cfg="y" ;;
        L) override_entry_name="${OPTARG}" ;;
        l) override_short_name="${OPTARG}" ;;
        a) override_arch_name="${OPTARG}" ;;
        b) override_boot_method="${OPTARG}" ;;
	u) read -r -a override_boot_uuids <<< "${OPTARG}" ;;
	K) read -r -a override_kernels <<< "${OPTARG}" ;;
	k) read -r -a override_kernel_sums <<< "${OPTARG}" ;;
	I) read -r -a override_initrds <<< "${OPTARG}" ;;
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

_out="$(realpath -q -- "${1}" || true)"

_set_overrides
_build
