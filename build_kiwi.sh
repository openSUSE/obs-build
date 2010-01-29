#!/bin/bash
run_kiwi()
{
    imagetype=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE imagetype)
    imagename=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE filename)
    imageversion=$(perl -I$BUILD_DIR -MBuild::Kiwi -e Build::Kiwi::show $BUILD_ROOT/$TOPDIR/SOURCES/$SPECFILE version)
    # prepare rpms as source and createrepo on the repositories
    if test -d $BUILD_ROOT/$TOPDIR/SOURCES/repos -a "$DO_INIT" = true ; then
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
	for imgtype in $imagetype ; do
	    case "$imgtype" in
		oem)
			    pushd $BUILD_ROOT/$TOPDIR/KIWI-oem > /dev/null
		    echo "compressing oem images... "
		    tar cvjfS $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-raw.tar.bz2 \
			--exclude=$imagename.$imagearch-$imageversion.iso \
			--exclude=$imagename.$imagearch-$imageversion.raw \
			* || cleanup_and_exit 1
		    sha256sum $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-raw.tar.bz2 \
			> "$BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-raw.tar.bz2.sha256" || cleanup_and_exit 1
		    if [ -e $imagename.$imagearch-$imageversion.iso ]; then
		      echo "take iso file and create sha256..."
		      mv $imagename.$imagearch-$imageversion.iso \
			 $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum.iso || cleanup_and_exit 1
			      pushd $BUILD_ROOT/$TOPDIR/KIWI > /dev/null
		      sha256sum $imagename.$imagearch-$imageversion$buildnum.iso \
			     > "$imagename.$imagearch-$imageversion$buildnum.iso.sha256" || cleanup_and_exit 1
		      popd > /dev/null
		    fi
		    if [ -e $imagename.$imagearch-$imageversion.raw ]; then
		      mv $imagename.$imagearch-$imageversion.raw \
			 $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum.raw || cleanup_and_exit 1
		      pushd $BUILD_ROOT/$TOPDIR/KIWI > /dev/null
		      echo "bzip2 raw file..."
		      bzip2 $imagename.$imagearch-$imageversion$buildnum.raw && \
		      echo "Create sha256 file..." && \
		      sha256sum $imagename.$imagearch-$imageversion$buildnum.raw.bz2 \
			     > "$imagename.$imagearch-$imageversion$buildnum.raw.bz2.sha256" || cleanup_and_exit 1
		      popd > /dev/null
		    fi
		    popd > /dev/null
		    ;;
		vmx)
		    pushd $BUILD_ROOT/$TOPDIR/KIWI-vmx > /dev/null
		    echo "compressing vmx images... "
		    # This option has a number of format parameters
		    FILES=""
		    for i in $imagename.$imagearch-$imageversion.vmx $imagename.$imagearch-$imageversion.vmdk $imagename.$imagearch-$imageversion.ovf \
		    	 $imagename.$imagearch-$imageversion-disk*.vmdk $imagename.$imagearch-$imageversion.xenconfig; do
		    	ls $i >& /dev/null && FILES="$FILES $i"
		    done
		    # kiwi is not removing the .rar file, if a different output format is defined. Do not include it by default.
		    [ -z "$FILES" ] && FILES="$imagename.$imagearch-$imageversion.raw"
		    tar cvjfS $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-vmx.tar.bz2 \
		    	$FILES || cleanup_and_exit 1
		    echo "Create sha256 file..."
		    sha256sum $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-vmx.tar.bz2 \
			     > "$BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-vmx.tar.bz2.sha256" || cleanup_and_exit 1
		    popd > /dev/null
		    ;;
		xen)
		    pushd $BUILD_ROOT/$TOPDIR/KIWI-xen > /dev/null
		    echo "compressing xen images... "
		    tar cvjfS $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-xen.tar.bz2 \
			`grep ^kernel $imagename.$imagearch-$imageversion.xenconfig | cut -d'"'  -f2` \
			`grep ^ramdisk $imagename.$imagearch-$imageversion.xenconfig | cut -d'"'  -f2` \
			$imagename.$imagearch-$imageversion.xenconfig \
			$imagename.$imagearch-$imageversion || cleanup_and_exit 1
		    popd > /dev/null
		    echo "Create sha256 file..."
		    sha256sum $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-xen.tar.bz2 \
			     > "$BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-xen.tar.bz2.sha256" || cleanup_and_exit 1
		    ;;
		pxe)
		    pushd $BUILD_ROOT/$TOPDIR/KIWI-pxe > /dev/null
		    echo "compressing pxe images... "
		    tar cvjfS $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-pxe.tar.bz2 \
				$imagename.$imagearch-$imageversion* \
				initrd-* || cleanup_and_exit 1
		    popd > /dev/null
		    echo "Create sha256 file..."
		    sha256sum $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-pxe.tar.bz2 \
			     > "$BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-pxe.tar.bz2.sha256" || cleanup_and_exit 1
		    ;;
		iso)
		    pushd $BUILD_ROOT/$TOPDIR/KIWI-iso > /dev/null
		    echo "creating sha256 sum for iso images... "
		    for i in *.iso; do
			pushd $BUILD_ROOT/$TOPDIR/KIWI/ > /dev/null
			mv $BUILD_ROOT/$TOPDIR/KIWI-iso/$i ${i%.iso}$buildnum.iso || cleanup_and_exit 1
			sha256sum ${i%.iso}$buildnum.iso > ${i%.iso}$buildnum.iso.sha256 || cleanup_and_exit 1
			popd > /dev/null
		    done
		    popd > /dev/null
		    ;;
		*)
		    pushd $BUILD_ROOT/$TOPDIR/KIWI-$imgtype > /dev/null
		    echo "compressing unkown images... "
		    tar cvjfS $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-$imgtype.tar.bz2 \
			* || cleanup_and_exit 1
		    echo "Create sha256 file..."
		    sha256sum $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-$imgtype.tar.bz2 \
			> $BUILD_ROOT/$TOPDIR/KIWI/$imagename.$imagearch-$imageversion$buildnum-$imgtype.tar.bz2.sha256 || cleanup_and_exit 1
			    popd > /dev/null
		    ;;
	    esac
	done
    fi
}
