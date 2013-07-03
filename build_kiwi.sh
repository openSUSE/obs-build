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
        if test "$imagetype" != product -a "$DO_INIT" != "false" ; then
	    echo "creating repodata for $repo"
	    if chroot $BUILD_ROOT createrepo --no-database --simple-md-filenames --help >/dev/null 2>&1 ; then
		chroot $BUILD_ROOT createrepo --no-database --simple-md-filenames "$repo"
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
    if test "$imagetype" = product ; then
	echo "running kiwi --create-instsource..."
	# runs always as abuild user
	mkdir -p "$BUILD_ROOT/$TOPDIR/KIWIROOT"
	chroot "$BUILD_ROOT" chown -R abuild.abuild "$TOPDIR"
	ver=`chroot "$BUILD_ROOT" su -c "/usr/sbin/kiwi --version | sed -n 's,.*kiwi version v\(.*\),\1,p'"`
        if [ ${ver:0:1} == "3" ]; then
          # old style kiwi 3 builds
	  chroot "$BUILD_ROOT" su -c "APPID=- LANG=POSIX /usr/sbin/kiwi --root $TOPDIR/KIWIROOT -v --logfile terminal -p $TOPDIR/SOURCES --instsource-local --create-instsource $TOPDIR/SOURCES" - abuild < /dev/null && BUILD_SUCCEEDED=true
          if [ ${ver:2:2} == "01" ]; then
            ## This block is obsolete with current kiwi versions, only needed for kiwi 3.01 version
            for i in $BUILD_ROOT/$TOPDIR/KIWIROOT/main/* ; do
                test -d "$i" || continue
                n="${i##*/}"
                test "$n" = scripts && continue
                test "$n" != "${n%0}" && continue
                chroot $BUILD_ROOT su -c "suse-isolinux $TOPDIR/KIWIROOT/main/$n $TOPDIR/KIWI/$n.iso" - $BUILD_USER
            done
          fi
        else
          if [ ${ver:0:1} == "4" -a ${ver:2:2} -lt 90 ]; then
            # broken kiwi version, not accepting verbose level
	    chroot "$BUILD_ROOT" su -c "APPID=- LANG=POSIX /usr/sbin/kiwi --root $TOPDIR/KIWIROOT -v -v --logfile terminal -p $TOPDIR/SOURCES --create-instsource $TOPDIR/SOURCES" - abuild < /dev/null && BUILD_SUCCEEDED=true
          else
            # current default
	    chroot "$BUILD_ROOT" su -c "APPID=- LANG=POSIX /usr/sbin/kiwi --root $TOPDIR/KIWIROOT -v 2 --logfile terminal -p $TOPDIR/SOURCES --create-instsource $TOPDIR/SOURCES" - abuild < /dev/null && BUILD_SUCCEEDED=true
          fi
        fi

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
	    if chroot $BUILD_ROOT su -c "cd $TOPDIR/SOURCES && kiwi --prepare $TOPDIR/SOURCES --logfile terminal --root $TOPDIR/KIWIROOT-$imgtype $KIWI_PARAMETERS" - root < /dev/null ; then
		echo "running kiwi --create for $imgtype..."
		mkdir -p $BUILD_ROOT/$TOPDIR/KIWI-$imgtype
		chroot $BUILD_ROOT su -c "cd $TOPDIR/SOURCES && kiwi --create $TOPDIR/KIWIROOT-$imgtype --logfile terminal --type $imgtype -d $TOPDIR/KIWI-$imgtype $KIWI_PARAMETERS" - root < /dev/null || cleanup_and_exit 1
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
# do not store compressed file _and_ uncompressed one
[ -e "$imageout.gz" ] && rm -f "$imageout"
if [ -e "$imageout.iso" ]; then
	echo "take iso file and create sha256..."
	mv "$imageout.iso" "/$TOPDIR/KIWI/$imageout$buildnum.iso"
	pushd /$TOPDIR/KIWI
	if [ -x /usr/bin/sha256sum ]; then
           /usr/bin/sha256sum "$imageout$buildnum.iso" > "$imageout$buildnum.iso.sha256"
        fi
	popd
fi
if [ -e "$imageout.install.iso" ]; then
	echo "take install.iso file and create sha256..."
	mv "$imageout.install.iso" "/$TOPDIR/KIWI/$imageout$buildnum.install.iso"
	pushd /$TOPDIR/KIWI
	if [ -x /usr/bin/sha256sum ]; then
           /usr/bin/sha256sum "$imageout$buildnum.install.iso" > "$imageout$buildnum.install.iso.sha256"
        fi
	popd
fi
if [ -e "$imageout.qcow2" ]; then
	mv "$imageout.qcow2" "/$TOPDIR/KIWI/$imageout$buildnum.qcow2"
	pushd /$TOPDIR/KIWI
	if [ -x /usr/bin/sha256sum ]; then
	    echo "Create sha256 file..."
	    /usr/bin/sha256sum "$imageout$buildnum.qcow2" > "$imageout$buildnum.qcow2.sha256"
        fi
	popd
fi
if [ -e "$imageout.raw.install.raw" ]; then
        compress_tool="bzip2"
        compress_suffix="bz2"
	if [ -x /usr/bin/xz ]; then
            # take xz to get support for sparse files
            compress_tool="xz -2"
            compress_suffix="xz"
        fi
	mv "$imageout.raw.install.raw" "/$TOPDIR/KIWI/$imageout$buildnum.raw.install.raw"
	pushd /$TOPDIR/KIWI
	echo "\$compress_tool raw.install.raw file..."
	\$compress_tool "$imageout$buildnum.raw.install.raw"
	if [ -x /usr/bin/sha256sum ]; then
	    echo "Create sha256 file..."
	    /usr/bin/sha256sum "$imageout$buildnum.raw.install.raw.\${compress_suffix}" > "$imageout$buildnum.raw.install.raw.\${compress_suffix}.sha256"
        fi
	popd
fi
if [ -e "$imageout.raw" ]; then
        compress_tool="bzip2"
        compress_suffix="bz2"
	if [ -x /usr/bin/xz ]; then
            # take xz to get support for sparse files
            compress_tool="xz -2"
            compress_suffix="xz"
        fi
	mv "$imageout.raw" "/$TOPDIR/KIWI/$imageout$buildnum.raw"
	pushd /$TOPDIR/KIWI
	echo "\$compress_tool raw file..."
	\$compress_tool "$imageout$buildnum.raw"
	if [ -x /usr/bin/sha256sum ]; then
	    echo "Create sha256 file..."
	    /usr/bin/sha256sum "$imageout$buildnum.raw.\${compress_suffix}" > "$imageout$buildnum.raw.\${compress_suffix}.sha256"
        fi
	popd
fi

tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-raw.tar.bz2" \
	--exclude="$imageout.iso" --exclude="$imageout.raw" --exclude="$imageout.qcow2" *
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
for suffix in "ovf" "qcow2"; do
  if [ -e "$imageout.\$suffix" ]; then
	mv "$imageout.\$suffix" "/$TOPDIR/KIWI/$imageout$buildnum.\$suffix"
	pushd /$TOPDIR/KIWI
	if [ -x /usr/bin/sha256sum ]; then
	    echo "Create sha256 \$suffix file..."
	    /usr/bin/sha256sum "$imageout$buildnum.\$suffix" > "$imageout$buildnum.\$suffix.sha256"
        fi
	popd
  fi
done
# This option has a number of format parameters
VMXFILES=""
SHAFILES=""
for i in "$imageout.vmx" "$imageout.vmdk" "$imageout-disk*.vmdk"; do
	test -e \$i && VMXFILES="\$VMXFILES \$i"
done
# take raw files as fallback
if [ -z "\$VMXFILES" ]; then
	test -e "$imageout.raw" && VMXFILES="$imageout.raw"
fi
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
# do not store compressed file _and_ uncompressed one
[ -e "$imageout.gz" ] && rm -f "$imageout"
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
# do not store compressed file _and_ uncompressed one
[ -e "$imageout.gz" ] && rm -f "$imageout"
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
		tbz)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
cd /$TOPDIR/KIWI-tbz
for i in *.tbz; do
        file=\$(readlink -f "\$i")
        [ -z "\$file" ] && echo readlink failed for $i
	mv "\$file" "/$TOPDIR/KIWI/\${i%.tbz}$buildnum.tbz"
done
if [ -x /usr/bin/sha256sum ]; then
   echo "creating sha256 sum for tar balls... "
   cd $TOPDIR/KIWI
   for i in *.tbz; do
	/usr/bin/sha256sum "\$i" > "\$i.sha256"
   done
fi
EOF
		    ;;
		*)
		    cat > $BUILD_ROOT/kiwi_post.sh << EOF
echo "compressing unkown images... "
cd /$TOPDIR/KIWI-$imgtype
# do not store compressed file _and_ uncompressed one
[ -e "$imageout.gz" ] && rm -f "$imageout"
tar cvjfS "/$TOPDIR/KIWI/$imageout$buildnum-$imgtype.tar.bz2" *
if [ -x /usr/bin/sha256sum ]; then
   echo "Create sha256 file..."
   cd /$TOPDIR/KIWI
   /usr/bin/sha256sum "$imageout$buildnum-$imgtype.tar.bz2" > "$imageout$buildnum-$imgtype.tar.bz2.sha256"
fi
EOF
		    ;;
	    esac
	    chroot $BUILD_ROOT su -c "sh -e /kiwi_post.sh" || cleanup_and_exit 1
	    rm -f $BUILD_ROOT/kiwi_post.sh
	done
    fi
    # Hook for running post kiwi build scripts like QA scripts if installed
    if [ -x $BUILD_ROOT/usr/lib/build/kiwi_post_run ]; then
        chroot $BUILD_ROOT su -c /usr/lib/build/kiwi_post_run || cleanup_and_exit 1
    fi
}
