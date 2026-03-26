all:

	asciidoc pbuild.adoc
	dos2unix index.html pbuild.html

install:
	install -m755 -d \
	    $(DESTDIR)$(docdir) \
	install -m644 \
	    pbuild.html \
	    $(DESTDIR)$(docdir)

