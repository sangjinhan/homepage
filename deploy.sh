#!/bin/sh

jekyll --no-auto
rsync -vaz _site/ sangjin@login.eecs.berkeley.edu:public_html
