#!/bin/sh

jekyll build
rsync -vaz _site/ sangjin@login.eecs.berkeley.edu:public_html
