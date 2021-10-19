all:

	asciidoc pbuild.adoc

install:
	install -m755 -d \
	    $(DESTDIR)$(docdir) \
	install -m644 \
	    pbuild.html \
	    $(DESTDIR)$(docdir)

