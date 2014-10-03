.PHONY: all install clean

all:
	@./build.sh

install:
	@./build.sh true

clean:
	rm -rf _build

github:
	git checkout gh-pages
	git merge master --no-edit
	$(MAKE)
	rm -f *.html
	cp _build/lib/conduit-all.docdir/* .
	git add *.html
	cp nice-style.css style.css
	git add style.css
	git commit -m 'sync ocamldoc' -a
	git push
	git checkout master
