#!/bin/bash
run_kiwi()
{
    imagetype=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE imagetype)
    imagename=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE filename)
    imageversion=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE version)
    # prepare rpms as source and createrepo on the repositories
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
	    if chroot $BUILD_ROOT createrepo --simple-md-filenames --help >/dev/null 2>&1 ; then
		chroot $BUILD_ROOT createrepo --simple-md-filenames "$repo"
	    else
		chroot $BUILD_ROOT createrepo "$repo"
	    fi
        fi
    done
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
	pushd /$TOPDIR/KIWI
	if [ -x /usr/bin/sha256sum ]; then
           /usr/bin/sha256sum "$imageout$buildnum.iso" > "$imageout$buildnum.iso.sha256"
        fi
	popd
fi
if [ -e "$imageout.raw" ]; then
	mv "$imageout.raw" "/$TOPDIR/KIWI/$imageout$buildnum.raw"
	pushd /$TOPDIR/KIWI
	echo "bzip2 raw file..."
	bzip2 "$imageout$buildnum.raw"
	if [ -x /usr/bin/sha256sum ]; then
	    echo "Create sha256 file..."
	    /usr/bin/sha256sum "$imageout$buildnum.raw.bz2" > "$imageout$buildnum.raw.bz2.sha256"
        fi
	popd
fi

tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-raw.tar.bz2" \
	--exclude="$imageout.iso" --exclude="$imageout.raw" *
cd /$TOPDIR/KIWI
if [ -x /usr/bin/sha256sum ]; then
   /usr/bin/sha256sum "$imageout$buildnum-raw.tar.bz2" > "$imageout$buildnum-raw.tar.bz2.sha256"
fi
EOF
		    ;;
		vmx)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing vmx images... "
cd /$TOPDIR/KIWI-vmx
# This option has a number of format parameters
VMXFILES=""
SHAFILES=""
for i in "$imageout.vmx" "$imageout.vmdk" "$imageout-disk*.vmdk" "$imageout.ovf"; do
	ls \$i >& /dev/null && VMXFILES="\$VMXFILES \$i"
done
if [ -n "\$VMXFILES" ]; then
	tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-vmx.tar.bz2" \$VMXFILES
	SHAFILES="\$SHAFILES $imageout$buildnum-vmx.tar.bz2"
fi

if [ -e "$imageout.xenconfig" ]; then
	tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-vmx.tar.bz2" $imageout.xenconfig $imageout.raw initrd-*
	SHAFILES="\$SHAFILES $imageout$buildnum-vmx.tar.bz2"
fi
# FIXME: do we need a single .raw file in any case ?

cd /$TOPDIR/KIWI
if [ -n "\$SHAFILES" -a -x /usr/bin/sha256sum ]; then
	for i in \$SHAFILES; do
		echo "Create sha256 file..."
		/usr/bin/sha256sum "\$i" > "\$i.sha256"
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
	initrd-* \
	"$imageout.xenconfig" \
	"$imageout"
if [ -x /usr/bin/sha256sum ]; then
   echo "Create sha256 file..."
   cd $TOPDIR/KIWI
   /usr/bin/sha256sum "$imageout$buildnum-xen.tar.bz2" > "$imageout$buildnum-xen.tar.bz2.sha256"
fi
EOF
		    ;;
		pxe)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing pxe images... "
cd /$TOPDIR/KIWI-pxe
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-pxe.tar.bz2" ${imageout}* initrd-*
if [ -x /usr/bin/sha256sum ]; then
   echo "Create sha256 file..."
   cd $TOPDIR/KIWI
   /usr/bin/sha256sum "$imageout$buildnum-pxe.tar.bz2" > "$imageout$buildnum-pxe.tar.bz2.sha256"
fi
EOF
		    ;;
		iso)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
cd /$TOPDIR/KIWI-iso
for i in *.iso; do
	mv "\$i" "/$TOPDIR/KIWI/\${i%.iso}$buildnum.iso"
done
if [ -x /usr/bin/sha256sum ]; then
   echo "creating sha256 sum for iso images... "
   cd $TOPDIR/KIWI
   for i in *.iso; do
	/usr/bin/sha256sum "\$i" > "\$i.sha256"
   done
fi
EOF
		    ;;
		*)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing unkown images... "
cd /$TOPDIR/KIWI-$imgtype
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-$imgtype.tar.bz2" *
if [ -x /usr/bin/sha256sum ]; then
   echo "Create sha256 file..."
   cd /$TOPDIR/KIWI
   /usr/bin/sha256sum "$imageout$buildnum-$imgtype.tar.bz2" > "$imageout$buildnum-$imgtype.tar.bz2.sha256"
fi
EOF
		    ;;
	    esac
	    chroot $BUILD_ROOT su -c "sh -x -e /kiwi_post.sh" || cleanup_and_exit 1
	    rm -f $BUILD_ROOT/kiwi_post.sh
	done
    fi
}
