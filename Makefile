.DEFAULT_GOAL := help

TITLE = hoge

.PHONY: help
help: ### Help
	@echo "Please use 'make <target>' where <target> is one of"
	@grep -E '^[a-zA-Z_-]+:.*?### .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?### "}; {printf "  \033[1;34m%-15s\033[0m-- %s\n", $$1, $$2}'

.PHONY: production
production: ### Build production HTML
	HUGO_ENV=production hugo --minify

.PHONY: html
html: ### Build HTML
	hugo -D

.PHONY: live
live: ### Start the Hugo server
	hugo server -D

.PHONY: dryrun
dryrun: production ### Deploy to production
	rsync -av --checksum --dry-run public/ yoshihisa-ya.sakura.ne.jp:/home/yoshihisa-ya/www/blog.yamano.dev/

.PHONY: deploy
deploy: production ### Deploy to production
	rsync -av --checksum public/ yoshihisa-ya.sakura.ne.jp:/home/yoshihisa-ya/www/blog.yamano.dev/

.PHONY: new
new: ### Add Some Content, TITLE=<post-title>
	hugo new posts/${TITLE}/index.md
