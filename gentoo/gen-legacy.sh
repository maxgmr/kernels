#!/bin/bash
# Generate 00-legacy-savedconfig.config: every option whose value in the running
# kernel's /proc/config.gz differs from the RAW (pre-olddefconfig) dist-kernel base.
set -euo pipefail
DF=/var/cache/distfiles
G=gentoo-kernel-config-g19

# Raw base, as kernel-build.eclass merges it for gentoo-kernel-6.18.62 with
# USE="-debug -modules-sign", amd64, KERNEL_IUSE_GENERIC_UKI=1 (last value wins):
#   kernel-6.18.12-gentoo/kernel-x86_64-fedora.config
#   CONFIG_LOCALVERSION="-gentoo-dist"
#   gentoo-kernel-config-g19/{base,6.12+,no-debug}.config
#   modules-sign.config (signing off)
#   module-compress.config (GENERIC_UKI)
# Excluded: values the toolchain computes (compiler/assembler/linker/rustc version and capability),
# and symbols without a prompt (see prompt_syms).
raw_base() {
    tar -xjOf "$DF/kernel-6.18.12-gentoo.tar.bz2" kernel-6.18.12-gentoo/kernel-x86_64-fedora.config
    echo 'CONFIG_LOCALVERSION="-gentoo-dist"'
    tar -xjOf "$DF/$G.tar.bz2" "$G/base.config"
    tar -xjOf "$DF/$G.tar.bz2" "$G/6.12+.config"
    tar -xjOf "$DF/$G.tar.bz2" "$G/no-debug.config"
    printf '%s\n' '# CONFIG_MODULE_SIG is not set' '# CONFIG_MODULE_SIG_ALL is not set' \
        '# CONFIG_MODULE_SIG_FORCE is not set' '# CONFIG_MODULE_SIG_KEY is not set'
    printf '%s\n' 'CONFIG_MODULE_COMPRESS=y' 'CONFIG_MODULE_COMPRESS_XZ=y' \
        '# CONFIG_MODULE_COMPRESS_ALL is not set'
}

# Symbols that have a prompt somewhere in the 6.18.62 Kconfig tree. Symbols without a prompt
# are computed by kconfig (select/default), so a value for them in a fragment is ignored.
# The Fedora config lists only prompt symbols, so without this filter ~1100 computed symbols
# (HAVE_*, ARCH_HAS_*, ...) would be emitted as "not in base".
prompt_syms() {
    # Only the files an x86 build sources: no other arch/*, no tools/, no kconfig self-tests.
    local K=/usr/src/linux-6.18.62-gentoo-dist
    find "$K" \( -path "$K/arch/*" -a ! -path "$K/arch/Kconfig" -a ! -path "$K/arch/x86" -a ! -path "$K/arch/x86/*" \) -prune -o \
        \( -path "$K/tools" -o -path "$K/scripts/kconfig/tests" \) -prune -o \
        -name 'Kconfig*' -type f -print0 |
        xargs -0 gawk '
		/^[ \t]*(menu)?config[ \t]+[A-Za-z0-9_]+/ { cur = $2; next }
		/^[ \t]*(choice|endchoice|comment|menu|endmenu|if|endif|source|mainmenu)([ \t]|$)/ { cur = ""; next }
		cur != "" && /^[ \t]*(bool|tristate|string|int|hex|prompt)[ \t]+["\x27]/ { print "CONFIG_" cur }
	' | sort -u
}

echo "# GENERATED $(date +%F) by gen-legacy.sh: every option in the 6.18.62 savedconfig"
echo "# (/proc/config.gz) that differs from the raw dist-kernel base (Fedora + Gentoo fragments)."
echo "# Do not hand-edit; entries move into hand-written fragments step by step."

gawk '
FILENAME == ARGV[1] { prompt[$0] = 1; next }
function parse(line,   m) {
	if (match(line, /^(CONFIG_[A-Za-z0-9_]+)=(.*)$/, m)) {
		key = m[1]; val = (m[2] == "n") ? "n" : m[2]; return 1
	}
	if (match(line, /^# (CONFIG_[A-Za-z0-9_]+) is not set$/, m)) {
		key = m[1]; val = "n"; return 1
	}
	return 0
}
function toolchain(k) {
	return k ~ /^CONFIG_(CC_VERSION_TEXT|GCC_VERSION|CLANG_VERSION|AS_VERSION|LD_VERSION|LLD_VERSION|RUSTC_VERSION|RUSTC_LLVM_VERSION|RUSTC_LLVM_MAJOR_VERSION|BINDGEN_VERSION_TEXT|PAHOLE_VERSION|RUST_IS_AVAILABLE)$/ ||
	       k ~ /^CONFIG_(CC|AS|LD|RUSTC|TOOLCHAIN)_(IS|HAS|CAN|SUPPORTS)_/ ||
	       k ~ /^CONFIG_(CC_HAVE_|GCC_ASM_|GCC10_NO_|LD_ORPHAN_WARN|AS_AVX|AS_SHA|AS_TPAUSE|AS_GFNI|AS_VAES|AS_VPCLMULQDQ|AS_WRUSS|CC_NO_|CC_ASM_)/
}
FILENAME == ARGV[2] { if (parse($0)) base[key] = val; next }
{
	if (!parse($0)) next
	if ((key in base) && base[key] == val) next
	if (toolchain(key)) { tc++; next }
	if (!(key in prompt)) { np++; next }
	print (val == "n") ? "# " key " is not set" : key "=" val
	n++
	if (!(key in base)) nobase++
}
END { printf "%d emitted (%d not in raw base); skipped: %d toolchain, %d without prompt\n", n, nobase, tc, np > "/dev/stderr" }
' <(prompt_syms) <(raw_base) <(zcat /proc/config.gz)
