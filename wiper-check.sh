#!/opt/bin/bash

target=$1
if [ -z "$target" ]; then
	echo "Usage:  $0 <mount_point|block_device>" >&2
	exit 1
fi

if [ $UID -ne 0 ]; then
	echo "Only the super-user can use this (try \"sudo $0\" instead), aborting." >&2
	exit 1
fi

function get_realpath() {
	iter=0
	p="$1"
	while [ -e "$p" -a $iter -lt 100 ]; do
		while [ "$p" != "/" -a "$p" != "${p%%/}" ]; do
			p="${p%%/}"
		done
		d="${p%/*}"
		t="${p##*/}"
		if [ "$d" != "" -a "$d" != "$p" ]; then
			cd -P "$d" || exit
			p="$t"
		fi
		if [ -d "$p" ]; then
			cd -P "$p" || exit
			pwd -P
			exit
		elif [ -h "$p" ]; then
			p=$($LS -ld "$p" | $GAWK '{sub("^[^>]*-[>] *",""); print}')
		elif [ -e "$p" ]; then
			[ "${p:0:1}" = "/" ] || p="`pwd -P`/$p"
			echo "$p"
			exit
		fi
		iter=$((iter + 1))
	done
}

function get_fsdir() {
	rw=""
	r=""
	while read -a m ; do
		pdev="${m[0]}"
		if [ "$pdev" = "$1" ]; then
			if [ "$rw" != "rw" ]; then
				rw="${m[3]:0:2}"
				r="${m[1]}"
			fi
		fi
	done
	echo -n "$r"
}

function get_fsdev(){
	get_realpath $(awk -v p="$1" '{if ($2 == p) r=$1} END{print r}' < /proc/mounts)
}

function get_major() {
	ls -ln "$1" | awk '{print gensub(",","",1,$5)}'
}

function sync_disks() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
	sleep 1
}

if [ -d "$target" ]; then
	fsdir="$target"
	fsdev=$(get_fsdev $fsdir)
	if [ "$fsdev" = "" ]; then
		echo "$fsdir: not found in /proc/mounts, aborting." >&2
		exit 1
	fi
elif [ -b "$target" ]; then
	fsdev="$target"
	fsdir=$(get_fsdir "$fsdev" < /proc/mounts)
	if [ "$fsdir" = "" ]; then
		echo "$fsdev: not found in /proc/mounts, aborting." >&2
		exit 1
	fi
else
	echo "$target: not a block device or mount point, aborting." >&2
	exit 1
fi

rawdev=$(get_realpath $(echo $fsdev | awk '{print gensub("[0-9]*$","","g")}'))
if [ ! -e "$rawdev" ]; then
	rawdev=""
elif [ ! -b "$rawdev" ]; then
	rawdev=""
elif [ $(get_major $fsdev) -ne $(get_major $rawdev) ]; then
	rawdev=""
fi
if [ "$rawdev" = "" ]; then
	echo "$fsdev: unable to reliably determine the underlying physical device name, aborting" >&2
	exit 1
fi

echo "Device: $rawdev"
echo "Mount: $fsdev on $fsdir"

tmpfile="$fsdir/${0##*/}_$$.tmp"

echo -n "Creating temporary file $tmpfile... "
str=$(seq -s ' ' 1000 9999)
for i in {0..99}; do
	echo "$str" >> $tmpfile
	if [ $? -ne 0 ]; then
		echo "File has not been written, aborting." >&2
		exit 1
	fi
done
sync_disks
echo

address=$(hdparm --fibmap $tmpfile | awk 'END {print $2}')
offset=$(hdparm -g $rawdev | awk 'END {print $NF}')
address=$(($address + $offset))

echo "First LBA for file: $address"

echo 'Before discarding:'
dd if=$rawdev bs=512 skip=$address count=1 2>/dev/null
echo

echo -n "Removing temporary file... "
rm $tmpfile
sync_disks
echo

echo
wiper.sh --commit --please-prematurely-wear-out-my-ssd --verbose $fsdev
if [ $? -ne 0 ]; then
	echo "Discarding was broken, aborting." >&2
	exit 1
fi
echo

sync_disks

echo 'After discarding:'
dd if=$rawdev bs=512 skip=$address count=1 2>/dev/null
echo
