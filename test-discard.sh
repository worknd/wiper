#!/usr/bin/env bash

[ -z "$try_change_provisioning_mode" ] && try_change_provisioning_mode=0

get_realpath() {
	local iter=0
	local p="$1"
	local d t
	while [ -e "$p" -a $iter -lt 100 ]; do
		while [ "$p" != "/" -a "$p" != "${p%%/}" ]; do
			p="${p%%/}"
		done
		d="${p%/*}"
		t="${p##*/}"
		if [ -n "$d" -a "$d" != "$p" ]; then
			cd -P "$d" || return
			p="$t"
		fi
		if [ -d "$p" ]; then
			cd -P "$p" || return
			pwd -P
			return
		elif [ -h "$p" ]; then
			p=$(ls -ld "$p")
			p="${p##* -> }"
		elif [ -e "$p" ]; then
			[ "${p:0:1}" = "/" ] || p="$(pwd -P)/$p"
			echo -n "$p"
			return
		fi
		iter=$((iter + 1))
	done
}

get_fsdir() {
	local dev="$1"
	local mdev mdir fs mode rw r
	while read mdev mdir fs mode ; do
		[ "$mdev" = "$dev" ] || mdev=$(get_realpath $mdev)
		if [ "$mdev" = "$dev" ]; then
			if [ "$rw" != "rw" ]; then
				rw="${mode:0:2}"
				r="$mdir"
			fi
		fi
	done < /proc/mounts
	echo -n "$r"
}

get_fsdev() {
	local dir="$1"
	get_realpath $(awk -v p=$dir '{if ($2 == p) {print $1;exit}}' < /proc/mounts)
}

get_major() {
	local dev="$1"
	ls -gn $dev | awk '{print gensub(",","",1,$4)}'
}

get_lba() {
	local dev="$1"
	local fname="$2"
	local res first bsize block lba
	if [[ $rawdev == *nvme* ]]; then
		res=$(debugfs -n -R "stats -h" $dev 2>/dev/null)
		first=$(echo -n "$res" | awk '/First block:/ {print $3;exit}')
		bsize=$(echo -n "$res" | awk '/Block size:/ {print $3;exit}')
		block=$(debugfs -n -R "bmap $fname 0" $1 2>/dev/null)
		fsoffset=$(hdparm -g $dev 2>/dev/null | awk 'END {print $NF}')
		if [ -n "$first" -a -n "$bsize" -a -n "$block" -a -n "$fsoffset" ]; then
			lba=$(($first + $fsoffset + $block * $bsize / 512))
		fi
	else
		lba=$(hdparm --fibmap $fname 2>/dev/null | awk 'END {print $2}')
	fi
	if [ $? -ne 0 -o -z "$lba" ]; then
		echo "$dev: filesystem is not supported, aborting." >&2
		return 1
	fi
	echo -n "$lba"
}

sync_disks() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
}

read_dev_sector() {
	local dev="$1"
	local offset="$2"
	local data
	data=$(dd if=$dev skip=$offset bs=512 count=1 2>/dev/null | strings)
	if [ $? -ne 0 ]; then
		echo "$dev: reading was broken, aborting." >&2
		return 1
	fi
	echo -n "$data"
}

change_option() {
	local dev="$1"
	local fname="$2"
	local default="$3"
	local opt
	opt="/sys/block/${dev##*/}/queue/$fname"
	[ -f $opt ] && [ $(cat $opt) -eq 0 ] && echo $default > $opt 2>/dev/null
	if [ $? -ne 0 ]; then
		echo "$dev: cannot change $fname, aborting." >&2
		return 1
	fi
}

target=$(get_realpath $1)
if [ -z "$target" ]; then
	echo "Usage:  $0 <mount_point|block_device>" >&2
	exit 1
fi

if [ -n "$EUID" -a "0$EUID" -ne 0 ]; then
	echo "Only the super-user can use this (try \"sudo $0\" instead), aborting." >&2
	exit 1
fi

if [ -d "$target" ]; then
	fsdir="$target"
	fsdev=$(get_fsdev $fsdir)
	if [ -z "$fsdev" ]; then
		echo "$fsdir: not found in /proc/mounts, aborting." >&2
		exit 1
	fi
elif [ -b "$target" ]; then
	fsdev="$target"
	fsdir=$(get_fsdir $fsdev)
	if [ -z "$fsdir" ]; then
		echo "$fsdev: not found in /proc/mounts, aborting." >&2
		exit 1
	fi
else
	echo "$target: not a block device or mount point, aborting." >&2
	exit 1
fi

rawdev=
maj=$(get_major $fsdev)
for p in $(ls /sys/block/); do
	rdev="/dev/$p"
	if [ -b $rdev -a $maj -eq $(get_major $rdev) ]; then
		rawdev=$rdev
		break
	fi
done
if [ -z "$rawdev" ]; then
	echo "$fsdev: unable to reliably determine the underlying physical device name, aborting" >&2
	exit 1
fi

echo "Device: $rawdev"
echo "Mount: $fsdev on $fsdir"

tmpfile="$fsdir/${0##*/}_$$.tmp"
[ "$fsdir" = "/" ] && tmpfile=${tmpfile//\/\//\/}

echo -n "Creating temporary file $tmpfile... "
seq -s '-' 1000 9999 > $tmpfile
if [ $? -ne 0 ]; then
	echo "The tile has not been written, aborting." >&2
	exit 1
fi
sync_disks
echo

lba=$(get_lba $fsdev $tmpfile)
if [ $? -ne 0 -o -z "$lba" ]; then
	rm -f $tmpfile
	exit 1
fi

state1=$(read_dev_sector $rawdev $lba)
if [ $? -ne 0 ]; then
	rm -f $tmpfile
	exit 1
fi
echo -e "Content of first file sector ($lba): ${state1//-1006*/...}"

echo -n "Removing the temporary file... "
rm -f $tmpfile
sync_disks
echo

state2=$(read_dev_sector $rawdev $lba)
[ $? -ne 0 ] && exit 1
echo -e "The sector content after removing file: ${state2//-1006*/...}"
if [ "$state2" != "$state1" ]; then
	echo "Content changed so TRIM works, exiting."
	exit 0
fi

if [ "0$try_change_provisioning_mode" -ne 0 ]; then
	echo -n "Preparing device for discarding (DANGEROUS)"

	find /sys/ -name provisioning_mode -exec grep -H . {} + |
	while read p; do
		[ "${p##*:}" != "unmap" ] && echo -n "unmap" > ${p%:*} 2>/dev/null && echo -n "."
		if [ $? -ne 0 ]; then
			echo "$fsdev: cannot change ${p##*/}, aborting." >&2
			exit 1
		fi
	done

	change_option $rawdev "discard_granularity" 512 && echo -n "." || exit 1
	change_option $rawdev "discard_max_bytes" 512 && echo -n "." || exit 1
	echo
fi

echo "Discarding whole filesystem..."
if which fstrim &>/dev/null; then
	fstrim -v $fsdir
elif which wiper.sh &>/dev/null; then
	wiper.sh --commit --please-prematurely-wear-out-my-ssd --verbose $fsdev
else
	echo "Program for discarding not found, aborting." >&2
	exit 1
fi
if [ $? -ne 0 ]; then
	echo "Discarding has been broken, aborting." >&2
	exit 1
fi

while :; do
	sync_disks
	state2=$(read_dev_sector $rawdev $lba)
	[ $? -ne 0 ] && exit 1
	echo -e "The sector content after discarding: ${state2//-1006*/...}"
	if [ "$state2" != "$state1" ]; then
		echo "Content changed so TRIM works, exiting."
		break
	fi

	echo "May be a bit later? Waiting..."
	sleep 3
done

exit 0
