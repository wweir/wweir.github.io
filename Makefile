# personal hugo commands set
OS_TYPE	= $(shell uname -s)
new 	=

default:
ifeq ("${new}", "")
	@$(MAKE) server
else
	@$(MAKE) new new="${new}"
endif

server:
ifeq ("${OS_TYPE}", "Darwin")
	open http://localhost:1313 &>/dev/null
endif
ifeq ("${OS_TYPE}", "Linux")
	xdg-open http://localhost:1313 &>/dev/null
endif

	hugo server --disableFastRender --buildDrafts

new:
ifeq ("${new}", "")
	@echo please set a TITLE for new article
	@exit 1
endif

	hugo new "post/${new}.md"

ifeq ("${OS_TYPE}", "Darwin")
	open -a Typora "content/post/${new}.md"
endif

publish:
	hugo --cleanDestinationDir --gc
	rm -rf /var/www/html_backup
	mv /var/www/html /var/www/html_backup
	mv -f public /var/www/html || mv /var/www/html_backup /var/www/html
	chown -R www-data:www-data /var/www/html
