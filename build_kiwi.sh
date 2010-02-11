#!/bin/bash
run_kiwi()
{
    imagetype=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE imagetype)
    imagename=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE filename)
    imageversion=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE version)
    # prepare rpms as source and createrepo on the repositories
    if test -d $BUILD_ROOT/$TOPDIR/SOURCES/repos -a "$DO_INIT" != false ; then
	(
	ln -sf $TOPDIR/SOURCES/repos $BUILD_ROOT/repos
	cd $BUILD_ROOT/$TOPDIR/SOURCES/repos
	for r in */* ; do
	    test -L $r && continue
	    test -d $r || continue
	    repo="$TOPDIR/SOURCES/repos/$r/"
	    # create compatibility link for old kiwi versions
	    rc="${r//:/:/}"
	    if test "$rc" != "$r" ; then
		rl="${rc//[^\/]}"
		rl="${rl//?/../}"
		mkdir -p "${rc%/*}"
		ln -s $rl$r "${rc%/*}/${rc##*/}"
		repo="$TOPDIR/SOURCES/repos/${rc%/*}/${rc##*/}/"
	    fi
	    if test "$imagetype" != product ; then
		echo "creating repodata for $repo"
		chroot $BUILD_ROOT createrepo "$repo"
	    fi
	done
	)
    fi
    # unpack root tar
    for t in $BUILD_ROOT/$TOPDIR/SOURCES/root.tar* ; do
	test -f $t || continue
	mkdir -p $BUILD_ROOT/$TOPDIR/SOURCES/root
	chroot $BUILD_ROOT tar -C $TOPDIR/SOURCES/root -xf "$TOPDIR/SOURCES/${t##*/}"
    done
    # fix script permissions
    chmod a+x $BUILD_ROOT/$TOPDIR/SOURCES/*.sh 2>/dev/null
    # unpack tar files in image directories
    if test -d $BUILD_ROOT/$TOPDIR/SOURCES/images ; then
	(
	cd $BUILD_ROOT/$TOPDIR/SOURCES/images
	for r in */* ; do
	    test -L $r && continue
	    test -d $r || continue
	    for t in $r/root.tar* ; do
		test -f $t || continue
		mkdir -p $r/root
		chroot $BUILD_ROOT tar -C $TOPDIR/SOURCES/images/$r/root -xf "$TOPDIR/SOURCES/images/$r/${t##*/}"
	    done
	    # fix script permissions
	    chmod a+x $BUILD_ROOT/$TOPDIR/SOURCES/images/$r/*.sh 2>/dev/null
	    # create compatibility link for old kiwi versions
	    rc="${r//:/:/}"
	    if test "$rc" != "$r" ; then
		rl="${rc//[^\/]}"
		rl="${rl//?/../}"
		mkdir -p "${rc%/*}"
		ln -s $rl$r "${rc%/*}/${rc##*/}"
	    fi
	done
	)
    fi
    rm -f $BUILD_ROOT/$TOPDIR/SOURCES/config.xml
    ln -s $SPECFILE $BUILD_ROOT/$TOPDIR/SOURCES/config.xml
    chroot $BUILD_ROOT su -c "kiwi --version" -
    if test "$imagetype" = product ; then
	echo "running kiwi --create-instsource..."
	# runs always as abuild user
	mkdir -p "$BUILD_ROOT/$TOPDIR/KIWIROOT"
	chroot "$BUILD_ROOT" chown -R abuild.abuild "$TOPDIR"
	# --instsource-local is only needed for openSUSE 11.1 and SLE 11 SP0 kiwi.
	chroot "$BUILD_ROOT" su -c "APPID=- LANG=POSIX /usr/sbin/kiwi --root $TOPDIR/KIWIROOT -v -v --logfile terminal -p $TOPDIR/SOURCES --instsource-local --create-instsource $TOPDIR/SOURCES" - abuild < /dev/null && BUILD_SUCCEEDED=true
### This block is obsolete with current kiwi versions, only needed for kiwi 3.01 version
#            for i in $BUILD_ROOT/$TOPDIR/KIWIROOT/main/* ; do
#                test -d "$i" || continue
#                n="${i##*/}"
#                test "$n" = scripts && continue
#                test "$n" != "${n%0}" && continue
#                chroot $BUILD_ROOT su -c "suse-isolinux $TOPDIR/KIWIROOT/main/$n $TOPDIR/KIWI/$n.iso" - $BUILD_USER
#            done

	# move created product to correct destination
	for i in $BUILD_ROOT/$TOPDIR/KIWIROOT/main/* ; do
	    test -e "$i" || continue
	    f=${i##*/}
	    case $f in
		*.iso) mv $i $BUILD_ROOT/$TOPDIR/KIWI/. ;;
		scripts) ;;
		*0) ;;
		*) test -d $i && mv $i $BUILD_ROOT/$TOPDIR/KIWI/. ;;
	    esac
	done
    else
	BUILD_SUCCEEDED=true
	if [ -z "$RUNNING_IN_VM" ]; then
	    # NOTE: this must be done with the outer system, because it loads the dm-mod kernel modules, which needs to fit to the kernel.
	    echo "starting device mapper for kiwi..."
	    [ -x /etc/init.d/boot.device-mapper ] && /etc/init.d/boot.device-mapper start
	fi
	for imgtype in $imagetype ; do
	    echo "running kiwi --prepare for $imgtype..."
	    # Do not use $BUILD_USER here, since we always need root permissions
	    if chroot $BUILD_ROOT su -c "cd $TOPDIR/SOURCES && kiwi --prepare $TOPDIR/SOURCES --logfile terminal --root $TOPDIR/KIWIROOT-$imgtype" - root < /dev/null ; then
		echo "running kiwi --create for $imgtype..."
		mkdir -p $BUILD_ROOT/$TOPDIR/KIWI-$imgtype
		chroot $BUILD_ROOT su -c "cd $TOPDIR/SOURCES && kiwi --create $TOPDIR/KIWIROOT-$imgtype --logfile terminal --type $imgtype -d $TOPDIR/KIWI-$imgtype" - root < /dev/null || cleanup_and_exit 1
	    else
		cleanup_and_exit 1
	    fi
	done

	# create tar.gz of images, in case it makes sense
	imagearch=`uname -m`
	buildnum=""
	  if test -n "$RELEASE"; then
	    buildnum="-Build$RELEASE"
	fi
	imageout="$imagename.$imagearch-$imageversion"
	for imgtype in $imagetype ; do
	    case "$imgtype" in
		oem)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing oem images... "
cd /$TOPDIR/KIWI-oem
if [ -e "$imageout.iso" ]; then
	echo "take iso file and create sha256..."
	mv "$imageout.iso" "/$TOPDIR/KIWI/$imageout$buildnum.iso"
	sha256sum "$imageout$buildnum.iso" > "$imageout$buildnum.iso.sha256"
fi

if [ -e "$imageout.raw" ]; then
	mv "$imageout.raw" "/$TOPDIR/KIWI/$imageout$buildnum.raw"
	echo "bzip2 raw file..."
	bzip2 "$imageout$buildnum.raw"
	echo "Create sha256 file..."
	sha256sum "$imageout$buildnum.raw.bz2" > "$imageout$buildnum.raw.bz2.sha256"
fi
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-raw.tar.bz2" \
	--exclude="$imageout.iso" --exclude="$imageout.raw" *

cd /$TOPDIR/KIWI
sha256sum "$imageout$buildnum-raw.tar.bz2" > "$imageout$buildnum-raw.tar.bz2.sha256"
EOF
		    ;;
		vmx)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing vmx images... "
cd /$TOPDIR/KIWI-vmx
# This option has a number of format parameters
VMXFILES=""
SHAFILES=""
for i in "$imageout.vmx" "$imageout.vmdk" "$imageout-disk*.vmdk"; do
	ls \$i >& /dev/null && VMXFILES="\$VMXFILES \$i"
done
if [ -n "\$VMXFILES" ]; then
	tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-vmx.tar.bz2" \$VMXFILES
	SHAFILES="\$SHAFILES $imageout$buildnum-vmx.tar.bz2"
fi

if [ -e "$imageout.xenconfig" ]; then
	tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-vmx.tar.bz2" $imageout.xenconfig $imageout.raw
	SHAFILES="\$SHAFILES $imageout$buildnum-vmx.tar.bz2"
fi
for i in "$imageout.ovf"; do
	[ -e \$i ] && SHAFILES="\$SHAFILES \$i"
done
# FIXME: do we need a single .raw file in any case ?

cd /$TOPDIR/KIWI
if [ -n "\$SHAFILES" ]; then
	for i in \$SHAFILES; do
		echo "Create sha256 file..."
		sha256sum "\$i" > "\$i.sha256"
	done
fi
EOF
		    ;;
		xen)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing xen images... "
cd /$TOPDIR/KIWI-xen
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-xen.tar.bz2" \
	`grep ^kernel $imageout.xenconfig | cut -d'"'  -f2` \
	`grep ^ramdisk $imageout.xenconfig | cut -d'"'  -f2` \
	"$imageout.xenconfig" \
	"$imageout"
echo "Create sha256 file..."
cd $TOPDIR/KIWI
sha256sum "$imageout$buildnum-xen.tar.bz2" > "$imageout$buildnum-xen.tar.bz2.sha256"
EOF
		    ;;
		pxe)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing pxe images... "
cd /$TOPDIR/KIWI-pxe
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-pxe.tar.bz2" "$imageout"* initrd-*"
echo "Create sha256 file..."
cd $TOPDIR/KIWI
sha256sum "$imageout$buildnum-pxe.tar.bz2" > "$imageout$buildnum-pxe.tar.bz2.sha256"
EOF
		    ;;
		iso)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
cd /$TOPDIR/KIWI-iso
for i in *.iso; do
	mv "\$i" "/$TOPDIR/KIWI/\${i%.iso}$buildnum.iso"
done
echo "creating sha256 sum for iso images... "
cd $TOPDIR/KIWI
for i in *.iso; do
	sha256sum "\$i" > "\$i.sha256"
done
EOF
		    ;;
		*)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing unkown images... "
cd /$TOPDIR/KIWI-$imgtype
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-$imgtype.tar.bz2" *
echo "Create sha256 file..."
cd /$TOPDIR/KIWI
sha256sum "$imageout$buildnum-$imgtype.tar.bz2" > "$imageout$buildnum-$imgtype.tar.bz2.sha256"
EOF
		    ;;
	    esac
	    chroot $BUILD_ROOT su -c "sh -e -x /kiwi_post.sh" || cleanup_and_exit 1
	    rm -f $BUILD_ROOT/kiwi_post.sh
	done
    fi
}
