PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
LISPDIR = $(PREFIX)/share/emacs/site-lisp
SWIFTC ?= swiftc
SWIFTFLAGS = -O -swift-version 6

SRCS = Sources/main.swift Sources/IO.swift Sources/Languages.swift \
	Sources/Pipe.swift Sources/Speller.swift Sources/TeX.swift \
	Sources/Grammar.swift

all: nsspell

nsspell: $(SRCS)
	$(SWIFTC) $(SWIFTFLAGS) -o nsspell $(SRCS)

install: nsspell
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LISPDIR)
	install -m 755 nsspell $(DESTDIR)$(BINDIR)/nsspell
	install -m 644 lisp/nsspell.el $(DESTDIR)$(LISPDIR)/nsspell.el

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/nsspell $(DESTDIR)$(LISPDIR)/nsspell.el

clean:
	rm -f nsspell *.o

.PHONY: all install uninstall clean
